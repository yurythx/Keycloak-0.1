#!/usr/bin/env bash
# =============================================================================
# deploy.sh - Sobe/atualiza a stack Keycloak (SSO da Prefeitura)
#
# Pre-requisito: rodar ./setup.sh pelo menos uma vez antes.
# Ver docs/01-provisionamento.md (Portoes de Validacao).
#
# Modo padrao (producao): puxa a imagem do Keycloak ja construida e
# escaneada pelo CI (.github/workflows/ci.yml) do GitHub Container Registry
# - nada e' buildado na VM. Use --build so' em dev/homologacao sem acesso
# ao registry.
#
# Uso:
#   ./deploy.sh                 pull (registry) + up -d, aguarda ficar healthy
#   ./deploy.sh --build          builda a imagem localmente em vez de puxar
#                                 (dev/homologacao sem acesso ao registry)
#   ./deploy.sh --no-pull        pula o "docker compose pull" (usa cache local)
#   ./deploy.sh --configure-ldap roda scripts/configure_ldap.sh apos a stack
#                                 subir (federacao com o Active Directory)
#   ./deploy.sh --logs           segue os logs apos o deploy ter sucesso
#   ./deploy.sh --no-menu        nao abre o ./manage.sh ao final (deploy so')
#   ./deploy.sh --down           derruba a stack (mantem o volume do Postgres)
#   ./deploy.sh --down --purge   derruba a stack E remove o volume (destrutivo!)
#   ./deploy.sh --timeout 300    tempo maximo de espera pelos healthchecks (s)
#
# Em sessao interativa (terminal de verdade), ao final de um deploy com
# sucesso o ./manage.sh abre automaticamente - use --no-menu pra desativar
# nessa execucao. Em automacao/CI (sem terminal) isso nunca acontece.
#
# O Portainer (opcional) e' controlado pelo ENABLE_PORTAINER no .env - ver
# ./setup.sh ou docs/scripts-referencia.md. Nao precisa de flag aqui.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=scripts/lib/theme.sh
source "scripts/lib/theme.sh"
# shellcheck source=scripts/lib/services.sh
source "scripts/lib/services.sh"

DO_BUILD=0
DO_PULL=1
DO_LOGS=0
DO_DOWN=0
PURGE=0
DO_LDAP=0
DO_MENU=1
TIMEOUT=240
NO_ANIM=0

while [ $# -gt 0 ]; do
    case "$1" in
        --build) DO_BUILD=1 ;;
        --no-pull) DO_PULL=0 ;;
        --configure-ldap) DO_LDAP=1 ;;
        --logs) DO_LOGS=1 ;;
        --no-menu) DO_MENU=0 ;;
        --down) DO_DOWN=1 ;;
        --purge) PURGE=1 ;;
        --yes|-y) ASSUME_YES=1 ;;
        --no-anim) NO_ANIM=1 ;;
        --timeout) shift; TIMEOUT="${1:-240}" ;;
        -h|--help)
            sed -n '2,31p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) die "Argumento desconhecido: $1 (use --help)" ;;
    esac
    shift
done
export ASSUME_YES NO_ANIM

print_header "DEPLOY - Build & Up"

# -----------------------------------------------------------------------------
step "Checagens de pre-voo (preflight)"
# -----------------------------------------------------------------------------
[ -f docker-compose.yml ] || die "docker-compose.yml nao encontrado - rode este script na raiz do repositorio"
command -v docker >/dev/null 2>&1 || die "Docker nao encontrado"
docker info >/dev/null 2>&1 || die "O daemon do Docker nao esta respondendo"
log_ok "Docker ativo"

[ -f .env ] || die ".env nao encontrado - rode ./setup.sh primeiro"
log_ok ".env presente"

for f in secrets/postgres_password.txt secrets/kc_admin_password.txt; do
    [ -s "$f" ] || die "$f ausente/vazio - rode ./setup.sh primeiro"
done
log_ok "Segredos presentes (secrets/*.txt)"

grep -qE '^PROXY_TRUSTED_ADDRESSES=.+$' .env 2>/dev/null || die "PROXY_TRUSTED_ADDRESSES ausente/vazio no .env - preencha com o IP do proxy reverso da prefeitura (rode ./setup.sh se precisar)"
log_ok "PROXY_TRUSTED_ADDRESSES presente no .env"

KEYCLOAK_BIND_V="$(grep -E '^KEYCLOAK_BIND=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
KEYCLOAK_PORT_V="$(grep -E '^KEYCLOAK_PORT=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
KEYCLOAK_BIND_V="${KEYCLOAK_BIND_V:-0.0.0.0}"
KEYCLOAK_PORT_V="${KEYCLOAK_PORT_V:-18443}"

# Sem checagem de certificado aqui: TLS e' responsabilidade do proxy
# reverso/balanceador da prefeitura, fora desta stack - o Keycloak so'
# serve HTTP puro na porta acima.
docker compose config --quiet || die "docker-compose.yml invalido (veja o erro acima)"
log_ok "docker-compose.yml validado (docker compose config)"

# Portainer e' um profile do compose - ativado via ENABLE_PORTAINER no .env
# (setup.sh pergunta isso). Exportado uma vez aqui pra todo "docker compose"
# do resto do script (pull/build/up/down) enxergar o mesmo profile.
PORTAINER_ON=0
if portainer_enabled; then
    PORTAINER_ON=1
    export COMPOSE_PROFILES=portainer
    log_ok "Portainer habilitado (ENABLE_PORTAINER=true no .env)"
else
    log_info "Portainer desativado (ENABLE_PORTAINER=false/ausente no .env)"
fi

# -----------------------------------------------------------------------------
if [ "$DO_DOWN" = "1" ]; then
    step "Derrubando a stack"
    if [ "$PURGE" = "1" ]; then
        confirm "${C_RED}Isso remove tambem o volume do Postgres (dados serao perdidos). Confirma?${C_RESET}" "N" \
            || die "Operacao cancelada pelo usuario"
        docker compose down -v
        log_warn "Stack derrubada e volume do Postgres removido"
    else
        docker compose down
        log_ok "Stack derrubada (volume do Postgres preservado)"
    fi
    exit 0
fi

# -----------------------------------------------------------------------------
step "Verificando conflitos de porta"
# -----------------------------------------------------------------------------
# So' importa aqui, nao no "Checagens de pre-voo" acima: nao faz sentido
# checar porta livre antes de um "--down" (nao vai subir nada), e um
# redeploy normal (stack ja rodando) sempre "ocupa" 80/443/9443 com o
# proprio conteiner desta stack - isso nao e' conflito nenhum, "docker
# compose up" so' recria no lugar. So' e' um problema real se a porta
# estiver ocupada por outra coisa, fora desta stack (ex.: um Apache
# esquecido rodando na VM "isolada" que devia estar so' com este servico).
port_in_use() {
    local port="$1"
    if command -v ss >/dev/null 2>&1; then
        ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"
    else
        # Fallback sem dependencia extra (ss pode faltar em imagens minimas):
        # tenta abrir uma conexao TCP - sucesso = algo esta escutando.
        (exec 3<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null
    fi
}

check_port() {
    local port="$1" label="$2" container="$3"
    docker inspect "$container" >/dev/null 2>&1 && return 0
    port_in_use "$port" || return 0
    die "Porta ${port} (${label}) ja esta em uso por outro processo nesta maquina, fora desta stack - confira com 'ss -tlnp | grep :${port}:' (root pra ver qual processo) antes de continuar"
}

check_port "$KEYCLOAK_PORT_V" "Keycloak" keycloak_server
if [ "$PORTAINER_ON" = "1" ]; then
    check_port 9443 "Portainer" portainer
fi
log_ok "Nenhum conflito de porta detectado"

# -----------------------------------------------------------------------------
if [ "$DO_BUILD" = "1" ]; then
    log_warn "Modo --build: buildando a imagem do Keycloak LOCALMENTE (nao usa o registry)"
    log_warn "Use isso so' em dev/homologacao - em producao prefira o modo padrao (pull do ghcr.io)"
elif [ "$DO_PULL" = "1" ]; then
    step "Baixando imagens do registry (Postgres e Keycloak via ghcr.io)"
    if ! docker compose pull; then
        log_err "Falha ao puxar as imagens."
        log_err "Se a imagem do Keycloak for privada no GitHub Container Registry, rode:"
        log_err "  echo \$GH_TOKEN | docker login ghcr.io -u <usuario> --password-stdin"
        log_err "(ou torne o pacote publico - ver docs/ci-cd.md)"
        die "Pull cancelado"
    fi
    log_ok "Pull concluido"
fi

# -----------------------------------------------------------------------------
if [ "$DO_BUILD" = "1" ]; then
    step "Subindo a stack (build local + up -d)"
    docker compose up -d --build
else
    step "Subindo a stack (up -d, imagem do registry)"
    docker compose up -d
fi
log_ok "docker compose up disparado"

# -----------------------------------------------------------------------------
step "Aguardando os contêineres ficarem healthy (timeout ${TIMEOUT}s)"
# -----------------------------------------------------------------------------
wait_healthy() {
    local name="$1" waited=0
    while (( waited < TIMEOUT )); do
        status="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}sem-healthcheck{{end}}' "$name" 2>/dev/null || echo "ausente")"
        case "$status" in
            healthy|sem-healthcheck) printf "\r"; log_ok "${name} -> ${status}"; return 0 ;;
            unhealthy) printf "\r"; log_err "${name} -> unhealthy"; return 1 ;;
            ausente) printf "\r"; log_err "${name} -> contêiner nao encontrado"; return 1 ;;
        esac
        printf "\r  %s…%s aguardando %-20s (%ss/%ss)" "${C_CYAN}" "${C_RESET}" "$name" "$waited" "$TIMEOUT"
        sleep 3
        waited=$((waited + 3))
    done
    printf "\r"
    log_err "${name} -> timeout aguardando ficar healthy"
    return 1
}

FAILED=0
for c in keycloak_db keycloak_server; do
    wait_healthy "$c" || FAILED=1
done
if [ "$PORTAINER_ON" = "1" ]; then
    wait_healthy "portainer" || FAILED=1
fi

if [ "$FAILED" = "1" ]; then
    step "Falha no deploy - ultimas linhas de log dos serviços"
    docker compose logs --tail=50
    die "Deploy falhou. Verifique os logs acima e docs/01-provisionamento.md."
fi

# -----------------------------------------------------------------------------
step "Validando Keycloak local (HTTP direto, antes do proxy da prefeitura)"
# -----------------------------------------------------------------------------
# So' testa a porta publicada localmente - nao valida o dominio publico nem
# TLS, pois isso agora e' responsabilidade do proxy reverso/balanceador da
# prefeitura, fora desta stack.
CHECK_HOST="$KEYCLOAK_BIND_V"
[ "$CHECK_HOST" = "0.0.0.0" ] && CHECK_HOST="127.0.0.1"
ROUTE_OK=0
for attempt in $(seq 1 10); do
    code="$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://${CHECK_HOST}:${KEYCLOAK_PORT_V}/realms/master/.well-known/openid-configuration" 2>/dev/null || echo 000)"
    if [ "$code" = "200" ]; then
        ROUTE_OK=1
        log_ok "Keycloak respondendo em http://${CHECK_HOST}:${KEYCLOAK_PORT_V} (HTTP ${code}, tentativa ${attempt}/10)"
        break
    fi
    sleep 3
done
if [ "$ROUTE_OK" = "0" ]; then
    log_warn "Keycloak ainda nao respondeu em ${CHECK_HOST}:${KEYCLOAK_PORT_V} apos 10 tentativas (~30s) - o contêiner esta healthy, mas confira 'docker compose logs keycloak'"
fi
log_info "Lembrete: aponte o proxy reverso da prefeitura para ${KEYCLOAK_BIND_V}:${KEYCLOAK_PORT_V} (HTTP) e confirme que ele envia X-Forwarded-Proto/Host corretos"

# -----------------------------------------------------------------------------
step "Configuracao LDAP/AD (opcional)"
if [ "$DO_LDAP" = "1" ]; then
    if [ -x scripts/configure_ldap.sh ]; then
        ./scripts/configure_ldap.sh || log_warn "configure_ldap.sh terminou com erro - stack continua no ar, veja a saida acima"
    else
        log_err "scripts/configure_ldap.sh nao encontrado ou sem permissao de execucao"
    fi
else
    log_info "Pulado (use --configure-ldap para rodar a federacao com o Active Directory)"
fi

# -----------------------------------------------------------------------------
step "Painel de servicos"
print_services_panel

if [ "$DO_BUILD" = "1" ]; then
    IMAGE_SRC_V="build local (dev/homologacao)"
else
    IMAGE_SRC_V="$(grep -E '^KEYCLOAK_IMAGE=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r'):$(grep -E '^KEYCLOAK_IMAGE_TAG=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
fi
print_panel "RESUMO DO DEPLOY" \
    "Imagem do Keycloak: ${IMAGE_SRC_V}" \
    "Portainer: $([ "$PORTAINER_ON" = "1" ] && echo "ativado" || echo "desativado")" \
    "" \
    "Gerenciar a stack (logs, reiniciar, backup...): ./manage.sh" \
    "Proximos portoes de validacao: docs/README.md"

printf "\n%sDeploy concluido.%s\n\n" "${C_BGREEN}" "${C_RESET}"

if [ "$DO_LOGS" = "1" ]; then
    docker compose logs -f
fi

# Abre o console de gerenciamento automaticamente em sessao interativa,
# a menos que --no-menu tenha sido passado ou isso ja tenha sido chamado
# de dentro do proprio manage.sh (evita menu dentro de menu quando a
# opcao "Atualizar" do manage.sh chama este script).
if [ "$DO_MENU" = "1" ] && [ -z "${MANAGE_SH_CONTEXT:-}" ] && [ -t 0 ] && [ -t 1 ] && [ -x ./manage.sh ]; then
    ./manage.sh
fi
