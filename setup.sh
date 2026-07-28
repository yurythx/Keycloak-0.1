#!/usr/bin/env bash
# =============================================================================
# setup.sh - Provisionamento inicial da stack Keycloak (SSO da Prefeitura)
#
# Idempotente: pode ser executado mais de uma vez sem sobrescrever segredos
# ou certificados ja existentes. Ver docs/00-pre-requisitos.md e docs/01-provisionamento.md.
#
# Uso:
#   ./setup.sh                 modo interativo (recomendado)
#   ./setup.sh --yes           aceita os padroes sem perguntar (CI/automacao)
#   ./setup.sh --no-anim       desativa a animacao de abertura
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=scripts/lib/theme.sh
source "scripts/lib/theme.sh"

ASSUME_YES=0
NO_ANIM=0

for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        --no-anim) NO_ANIM=1 ;;
        -h|--help)
            echo "Uso: ./setup.sh [--yes] [--no-anim]"
            exit 0
            ;;
        *) die "Argumento desconhecido: $arg (use --help)" ;;
    esac
done
export ASSUME_YES NO_ANIM

trap 'log_err "Setup interrompido na linha $LINENO. Nenhuma alteracao destrutiva foi feita."' ERR

print_header "SETUP - Provisionamento Inicial"

# -----------------------------------------------------------------------------
step "Verificando pre-requisitos"
# -----------------------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "Docker nao encontrado. Instale o Docker Engine antes de continuar."
log_ok "Docker encontrado: $(docker --version)"

docker compose version >/dev/null 2>&1 || die "Docker Compose v2 (plugin) nao encontrado."
log_ok "Docker Compose: $(docker compose version --short 2>/dev/null || echo v2)"

docker info >/dev/null 2>&1 || die "O daemon do Docker nao esta respondendo. Ele esta rodando?"
log_ok "Daemon do Docker respondendo"

command -v openssl >/dev/null 2>&1 || die "openssl nao encontrado (necessario para gerar segredos/certificados)."
log_ok "openssl encontrado: $(openssl version)"

# -----------------------------------------------------------------------------
step "Preparando estrutura de diretorios"
# -----------------------------------------------------------------------------
mkdir -p secrets certs
log_ok "secrets/  certs/"

# -----------------------------------------------------------------------------
step "Configurando .env"
# -----------------------------------------------------------------------------
if [ -f .env ]; then
    log_info ".env ja existe - mantendo valores atuais (apague o arquivo para reconfigurar do zero)"
    # Auto-migracao: .env de uma versao anterior (com Traefik na stack) nao
    # tem KEYCLOAK_BIND/KEYCLOAK_PORT - agora o Keycloak publica a porta
    # direto no host, pro proxy reverso da prefeitura encaminhar pra ca.
    if ! grep -qE '^KEYCLOAK_PORT=' .env 2>/dev/null; then
        printf '\nKEYCLOAK_BIND=0.0.0.0\nKEYCLOAK_PORT=18443\n' >> .env
        log_warn ".env de uma versao anterior (com Traefik) - adicionado KEYCLOAK_BIND=0.0.0.0 e KEYCLOAK_PORT=18443. Confira o firewall antes do deploy (ver etapa 'Proxy reverso externo' abaixo)"
    fi
    if grep -qE '^PROXY_TRUSTED_ADDRESSES=(172\.16\.0\.0/12)?$' .env 2>/dev/null; then
        log_warn "PROXY_TRUSTED_ADDRESSES esta vazio ou no valor antigo (faixa Docker) - troque pelo IP real do proxy reverso da prefeitura em .env antes do deploy"
    fi
else
    [ -f .env.example ] || die ".env.example nao encontrado no repositorio"
    cp .env.example .env
    log_ok ".env criado a partir de .env.example"

    POSTGRES_DB_V=$(ask "Nome do banco Postgres" "keycloak")
    POSTGRES_USER_V=$(ask "Usuario do Postgres" "keycloak_user")
    KC_ADMIN_USER_V=$(ask "Usuario admin inicial do Keycloak" "kc_admin")
    KC_HOSTNAME_V=$(ask "Hostname publico (https://...)" "https://sso.rondonopolis.mt.gov.br")

    PROXY_TRUSTED_V=$(ask "IP (ou CIDR) do proxy reverso da prefeitura que vai encaminhar pra essa stack" "")
    while [ -z "$PROXY_TRUSTED_V" ]; do
        log_warn "Obrigatorio - sem isso o Keycloak nao confia no X-Forwarded-Proto e gera link http:// nos fluxos OIDC"
        PROXY_TRUSTED_V=$(ask "IP (ou CIDR) do proxy reverso da prefeitura" "")
    done
    KEYCLOAK_PORT_V=$(ask "Porta no host onde o Keycloak fica exposto pro proxy da prefeitura encaminhar" "18443")
    KEYCLOAK_BIND_V=$(ask "IP de bind dessa porta (0.0.0.0 se o proxy estiver em outra maquina; 127.0.0.1 se for na mesma maquina)" "0.0.0.0")

    AD_DOMAIN_V=$(ask "Dominio do Active Directory" "rondonopolis.local")
    AD_DC_HOST_V=$(ask "Hostname do Domain Controller" "dc01.rondonopolis.local")
    AD_DC_IP_V=$(ask "IP do Domain Controller" "192.168.1.10")
    KC_LOG_LEVEL_V=$(ask "Nivel de log do Keycloak" "INFO")

    ENABLE_PORTAINER_V="false"
    if confirm "Subir o Portainer junto (gerenciador visual do Docker, so' acessivel via 127.0.0.1:9443/SSH tunnel por padrao)?" "N"; then
        ENABLE_PORTAINER_V="true"
    fi

    cat > .env <<EOF
# Gerado por setup.sh em $(date '+%F %T')
POSTGRES_DB=${POSTGRES_DB_V}
POSTGRES_USER=${POSTGRES_USER_V}

KC_BOOTSTRAP_ADMIN_USERNAME=${KC_ADMIN_USER_V}

KC_HOSTNAME=${KC_HOSTNAME_V}
PROXY_TRUSTED_ADDRESSES=${PROXY_TRUSTED_V}
KEYCLOAK_BIND=${KEYCLOAK_BIND_V}
KEYCLOAK_PORT=${KEYCLOAK_PORT_V}

AD_DOMAIN=${AD_DOMAIN_V}
AD_DC_HOSTNAME=${AD_DC_HOST_V}
AD_DC_IP=${AD_DC_IP_V}

KC_LOG_LEVEL=${KC_LOG_LEVEL_V}

# Imagem do Keycloak publicada pelo CI (ver .github/workflows/ci.yml).
# Em producao, prefira travar KEYCLOAK_IMAGE_TAG num "sha-xxxxxxx" especifico
# em vez de "latest".
KEYCLOAK_IMAGE=ghcr.io/yurythx/keycloak-sso
KEYCLOAK_IMAGE_TAG=latest

# Portainer (opcional). PORTAINER_BIND=127.0.0.1 so' permite acesso via
# SSH tunnel/VPN - mude com cuidado (ver docs/scripts-referencia.md).
ENABLE_PORTAINER=${ENABLE_PORTAINER_V}
PORTAINER_BIND=127.0.0.1
EOF
    log_ok ".env preenchido"
fi

# -----------------------------------------------------------------------------
step "Gerando segredos (32 caracteres alfanumericos)"
# -----------------------------------------------------------------------------
# Alfanumerico puro (sem +, / ou =) de proposito: segredos base64 "crus"
# quebram testes com 'curl -d' sem --data-urlencode (o '+' vira espaco).
# Ver docs/02-configuracao-keycloak.md.
gen_secret() {
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 32
}

# O Keycloak (e o Postgres) rodam como usuario nao-root dentro do
# container, mas com GID 0 (grupo "root") - convencao tipo OpenShift
# (confirmado: uid=1000(keycloak) gid=0(root)). O "secrets:" do Docker
# Compose fora do modo Swarm e' um bind mount simples - ele NAO remapeia
# dono/grupo, preserva exatamente a permissao que o arquivo tem no HOST.
# Por isso o arquivo precisa ser legivel pelo grupo 0, senao o container
# recebe "Permission denied" ao ler /run/secrets/* (achado real: stack
# quebrou em producao com os arquivos em 600/root:root, ilegiveis pelo
# processo do Keycloak). 640 + grupo 0 resolve sem tornar o arquivo
# legivel por qualquer usuario do host (evita ir ate 644/world-readable).
fix_secret_perms() {
    local file="$1"
    if chgrp 0 "$file" 2>/dev/null; then
        chmod 640 "$file"
    else
        chmod 644 "$file"
        log_warn "$(basename "$file"): nao foi possivel ajustar o grupo para 0 (root) - usando 644"
    fi
}

make_secret_file() {
    local file="$1" label="$2"
    if [ -s "$file" ]; then
        log_info "${label} ja existe em ${file} - mantendo valor atual (so ajustando permissao)"
    else
        gen_secret > "$file"
        log_ok "${label} gerado -> ${file} (32 chars)"
    fi
    fix_secret_perms "$file"
}

make_secret_file "secrets/postgres_password.txt" "Senha do Postgres"
make_secret_file "secrets/kc_admin_password.txt" "Senha do admin do Keycloak"

# -----------------------------------------------------------------------------
step "Proxy reverso externo"
# -----------------------------------------------------------------------------
# TLS, redirect HTTP->HTTPS e balanceamento agora sao responsabilidade do
# servidor web da prefeitura, fora desta stack. O Keycloak so publica a
# porta KEYCLOAK_PORT em HTTP puro - o proxy externo termina o TLS e
# encaminha pra ca. Aqui so validamos que o .env esta coerente.
PROXY_TRUSTED_SHOW="$(grep -E '^PROXY_TRUSTED_ADDRESSES=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
KEYCLOAK_BIND_SHOW="$(grep -E '^KEYCLOAK_BIND=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
KEYCLOAK_PORT_SHOW="$(grep -E '^KEYCLOAK_PORT=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"

if [ -z "$PROXY_TRUSTED_SHOW" ]; then
    log_warn "PROXY_TRUSTED_ADDRESSES esta vazio em .env - preencha com o IP do proxy da prefeitura antes do deploy, senao o Keycloak nao confia no X-Forwarded-Proto"
else
    log_ok "PROXY_TRUSTED_ADDRESSES=${PROXY_TRUSTED_SHOW}"
fi
log_ok "Keycloak vai publicar em ${KEYCLOAK_BIND_SHOW:-0.0.0.0}:${KEYCLOAK_PORT_SHOW:-18443} -> 8080 (HTTP puro)"
log_warn "Confirme no firewall do host (iptables/ufw) que a porta ${KEYCLOAK_PORT_SHOW:-18443} so' aceita conexao vinda do IP do proxy da prefeitura"

# -----------------------------------------------------------------------------
step "CA do Active Directory (necessaria na Etapa 3, docs/03-federacao-ad.md)"
# -----------------------------------------------------------------------------
if [ -s certs/ad-ca.pem ]; then
    log_ok "certs/ad-ca.pem presente"
else
    log_info "certs/ad-ca.pem ainda nao foi copiado - so e necessario para a federacao LDAPS (Etapa 3), nao bloqueia o deploy inicial"
fi

# -----------------------------------------------------------------------------
# Resumo
# -----------------------------------------------------------------------------
STATUS_ENV="OK"
STATUS_SECRETS="OK"
STATUS_PROXY="${KEYCLOAK_BIND_SHOW:-0.0.0.0}:${KEYCLOAK_PORT_SHOW:-18443} (aguardando proxy da prefeitura)"
STATUS_PORTAINER="desativado"
grep -qE '^ENABLE_PORTAINER=true' .env 2>/dev/null && STATUS_PORTAINER="ativado (127.0.0.1:9443)"

print_panel "RESUMO DO SETUP" \
    ".env ................... ${STATUS_ENV}" \
    "secrets/*.txt ........... ${STATUS_SECRETS}" \
    "Keycloak exposto em ..... ${STATUS_PROXY}" \
    "Portainer ............... ${STATUS_PORTAINER}" \
    "" \
    "Proximo passo: ./deploy.sh" \
    "Referencia completa: docs/README.md"

printf "\n%sSetup concluido.%s\n\n" "${C_BGREEN}" "${C_RESET}"
