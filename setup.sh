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
    # Auto-migracao: .env de antes do Vaultwarden entrar na stack nao tem
    # essas variaveis - adiciona com os padroes pra "docker compose config"
    # nao quebrar (VW_POSTGRES_USER/DB tem default no compose, mas o
    # secret precisa existir - ver make_secret_file abaixo).
    if ! grep -qE '^VW_POSTGRES_DB=' .env 2>/dev/null; then
        printf '\nVW_POSTGRES_DB=vaultwarden\nVW_POSTGRES_USER=vw_user\nVAULTWARDEN_VERSION=latest\nVAULTWARDEN_BIND=192.168.0.225\nVAULTWARDEN_HTTP_PORT=8081\nVAULTWARDEN_WS_PORT=3012\n' >> .env
        log_warn ".env sem variaveis do Vaultwarden - adicionadas com os padroes (confira VAULTWARDEN_BIND=192.168.0.225 - precisa ser um IP que esta VM realmente tenha)"
    fi
    if ! grep -qE '^VAULTWARDEN_SSO_ENABLED=' .env 2>/dev/null; then
        printf '\nVAULTWARDEN_DOMAIN=https://cofre.rondonopolis.mt.gov.br\nVAULTWARDEN_SSO_ENABLED=true\nVAULTWARDEN_SSO_AUTHORITY=https://sso.rondonopolis.mt.gov.br/realms/Prefeitura\nVAULTWARDEN_SSO_CLIENT_ID=vaultwarden-sso\n' >> .env
        log_warn ".env sem variaveis do Vaultwarden/SSO - adicionadas com os padroes desta prefeitura (SSO LIGADO por padrao). Confira VAULTWARDEN_DOMAIN e, ANTES do deploy, confirme o client 'vaultwarden-sso' no realm 'Prefeitura' do Keycloak (redirectUris apontando pro VAULTWARDEN_DOMAIN real) e cole o secret em secrets/vw_sso_client_secret.txt (ver docs/06-vaultwarden.md#sso) - senao o deploy.sh recusa subir"
    fi
    if grep -qE '^VAULTWARDEN_DOMAIN=$' .env 2>/dev/null; then
        log_warn "VAULTWARDEN_DOMAIN esta vazio no .env - o Vaultwarden RECUSA subir sem isso (precisa ser http[s]://... , achado real testando esta stack). Preencha antes do deploy"
    fi
    if ! grep -qE '^VAULTWARDEN_INITIAL_USER_EMAIL=' .env 2>/dev/null; then
        printf '\nVAULTWARDEN_INITIAL_USER_EMAIL=\nVAULTWARDEN_INITIAL_USER_NAME="Suporte TI"\n' >> .env
        log_warn ".env sem VAULTWARDEN_INITIAL_USER_EMAIL - adicionado vazio (deploy.sh nao cria conta inicial nenhuma ate voce preencher e rodar ./setup.sh de novo pra gerar secrets/vw_initial_user_password.txt)"
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

    VW_POSTGRES_DB_V=$(ask "Nome do banco do Vaultwarden" "vaultwarden")
    VW_POSTGRES_USER_V=$(ask "Usuario do Postgres do Vaultwarden" "vw_user")
    VAULTWARDEN_BIND_V=$(ask "IP do host onde o Vaultwarden fica exposto pro proxy da prefeitura encaminhar" "192.168.0.225")
    VAULTWARDEN_HTTP_PORT_V=$(ask "Porta HTTP do Vaultwarden nesse IP" "8081")
    VAULTWARDEN_WS_PORT_V=$(ask "Porta do WebSocket do Vaultwarden (sincronizacao em tempo real)" "3012")
    VAULTWARDEN_DOMAIN_V=$(ask "URL publica do Vaultwarden (https://...)" "https://cofre.rondonopolis.mt.gov.br")
    while [ -z "$VAULTWARDEN_DOMAIN_V" ]; do
        log_warn "Obrigatorio - o Vaultwarden recusa subir sem isso (precisa conter http:// ou https://)"
        VAULTWARDEN_DOMAIN_V=$(ask "URL publica do Vaultwarden (https://...)" "https://cofre.rondonopolis.mt.gov.br")
    done

    VAULTWARDEN_SSO_ENABLED_V="false"
    VAULTWARDEN_SSO_AUTHORITY_V=""
    VAULTWARDEN_SSO_CLIENT_ID_V="vaultwarden-sso"
    # SSO ligado por padrao nesta prefeitura (default "S") - precisa do
    # client "vaultwarden-sso" ja criado no realm "Prefeitura" do Keycloak
    # ANTES do deploy, senao o Vaultwarden recusa subir (mesmo
    # tratamento do VAULTWARDEN_DOMAIN acima) - deploy.sh confere isso.
    if confirm "Login do Vaultwarden via SSO do Keycloak (precisa do client OIDC 'vaultwarden-sso' ja criado no realm 'Prefeitura' - ver docs/06-vaultwarden.md#sso)?" "S"; then
        VAULTWARDEN_SSO_ENABLED_V="true"
        VAULTWARDEN_SSO_AUTHORITY_V=$(ask "URL do realm no Keycloak" "https://sso.rondonopolis.mt.gov.br/realms/Prefeitura")
        VAULTWARDEN_SSO_CLIENT_ID_V=$(ask "Client ID cadastrado no Keycloak para o Vaultwarden" "vaultwarden-sso")
        log_warn "Cole o CLIENT SECRET desse client em secrets/vw_sso_client_secret.txt antes do deploy (nao e' gerado por este script - precisa bater com o valor do Keycloak, e o client precisa existir de verdade)"
    fi

    VAULTWARDEN_INITIAL_USER_EMAIL_V=$(ask "E-mail da conta inicial do Vaultwarden (Enter pra nao criar nenhuma automaticamente)" "")
    VAULTWARDEN_INITIAL_USER_NAME_V="Suporte TI"
    if [ -n "$VAULTWARDEN_INITIAL_USER_EMAIL_V" ]; then
        VAULTWARDEN_INITIAL_USER_NAME_V=$(ask "Nome dessa conta" "Suporte TI")
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

# Vaultwarden (cofre de senhas) - stack separada da SSO do Keycloak,
# mesmo proxy reverso externo da prefeitura encaminha pra ca.
VW_POSTGRES_DB=${VW_POSTGRES_DB_V}
VW_POSTGRES_USER=${VW_POSTGRES_USER_V}
VAULTWARDEN_VERSION=latest
VAULTWARDEN_BIND=${VAULTWARDEN_BIND_V}
VAULTWARDEN_HTTP_PORT=${VAULTWARDEN_HTTP_PORT_V}
VAULTWARDEN_WS_PORT=${VAULTWARDEN_WS_PORT_V}
VAULTWARDEN_DOMAIN=${VAULTWARDEN_DOMAIN_V}

# SSO do Vaultwarden contra o Keycloak - client secret NAO vai aqui,
# fica em secrets/vw_sso_client_secret.txt (ver docs/06-vaultwarden.md#sso)
VAULTWARDEN_SSO_ENABLED=${VAULTWARDEN_SSO_ENABLED_V}
VAULTWARDEN_SSO_AUTHORITY=${VAULTWARDEN_SSO_AUTHORITY_V}
VAULTWARDEN_SSO_CLIENT_ID=${VAULTWARDEN_SSO_CLIENT_ID_V}

# Conta inicial do Vaultwarden - deploy.sh garante que existe em todo
# deploy (idempotente). Senha fica em secrets/vw_initial_user_password.txt
VAULTWARDEN_INITIAL_USER_EMAIL=${VAULTWARDEN_INITIAL_USER_EMAIL_V}
VAULTWARDEN_INITIAL_USER_NAME="${VAULTWARDEN_INITIAL_USER_NAME_V}"
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
make_secret_file "secrets/vw_postgres_password.txt" "Senha do Postgres do Vaultwarden"
# Token do painel /admin do Vaultwarden - com SIGNUPS_ALLOWED=false (ver
# docker-compose.yml), e' por ali que contas de usuario sao criadas.
make_secret_file "secrets/vw_admin_token.txt" "Token do admin do Vaultwarden"

# Client secret do SSO (Vaultwarden -> Keycloak) - NAO gerado aleatorio
# (precisa bater com o valor configurado no client OIDC do Keycloak, ver
# docs/06-vaultwarden.md#sso). So' garante que o arquivo existe (vazio
# = SSO desligado funciona normal, ver VAULTWARDEN_SSO_ENABLED acima) -
# "docker compose" precisa do arquivo presente mesmo com o secret vazio.
if [ ! -f secrets/vw_sso_client_secret.txt ]; then
    : > secrets/vw_sso_client_secret.txt
    fix_secret_perms "secrets/vw_sso_client_secret.txt"
    log_info "secrets/vw_sso_client_secret.txt criado vazio - preencha com o client secret do Keycloak se for usar SSO (ver docs/06-vaultwarden.md#sso)"
else
    fix_secret_perms "secrets/vw_sso_client_secret.txt"
fi

# Senha da conta inicial do Vaultwarden (scripts/vaultwarden_bootstrap_account.sh,
# chamado pelo deploy.sh, cria essa conta automaticamente se ainda nao
# existir). So' pergunta se VAULTWARDEN_INITIAL_USER_EMAIL estiver preenchido
# no .env e o arquivo ainda nao existir - nunca sobrescreve uma senha ja
# gravada (a conta pode ja existir de verdade, mudar o arquivo nao muda a
# senha dela).
VW_INITIAL_EMAIL_SHOW="$(grep -E '^VAULTWARDEN_INITIAL_USER_EMAIL=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
if [ -n "$VW_INITIAL_EMAIL_SHOW" ]; then
    if [ -s secrets/vw_initial_user_password.txt ]; then
        log_info "Senha da conta inicial do Vaultwarden ja existe em secrets/vw_initial_user_password.txt - mantendo"
    else
        VW_INITIAL_PW_V="$(ask_secret "Senha da conta inicial do Vaultwarden (${VW_INITIAL_EMAIL_SHOW})")"
        if [ -z "$VW_INITIAL_PW_V" ]; then
            log_warn "Nenhuma senha informada - secrets/vw_initial_user_password.txt nao foi criado. deploy.sh vai pular a criacao dessa conta ate voce preencher esse arquivo"
        else
            printf '%s' "$VW_INITIAL_PW_V" > secrets/vw_initial_user_password.txt
            fix_secret_perms "secrets/vw_initial_user_password.txt"
            log_ok "Senha da conta inicial do Vaultwarden gravada -> secrets/vw_initial_user_password.txt"
        fi
    fi
fi

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
