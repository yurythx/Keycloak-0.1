#!/usr/bin/env bash
# =============================================================================
# configure_vaultwarden_sso.sh - Assistente de integracao SSO
# Vaultwarden <-> Keycloak (docs/06-vaultwarden.md#sso), automatizado via
# kcadm.sh (mesmo padrao do scripts/configure_ldap.sh).
#
# Idempotente: se o client OIDC ja existir no Keycloak (mesmo clientId),
# atualiza o redirect URI/web origin em vez de duplicar, e reaproveita o
# secret existente por padrao.
#
# Pre-requisito: keycloak_server rodando e saudavel (rode ./deploy.sh antes).
#
# Uso:
#   ./scripts/configure_vaultwarden_sso.sh              interativo
#   ./scripts/configure_vaultwarden_sso.sh --yes        aceita os padroes sem perguntar
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=scripts/lib/theme.sh
source "scripts/lib/theme.sh"

for arg in "$@"; do
    case "$arg" in
        --yes|-y) ASSUME_YES=1 ;;
        -h|--help)
            echo "Uso: ./scripts/configure_vaultwarden_sso.sh [--yes]"
            exit 0
            ;;
        *) die "Argumento desconhecido: $arg (use --help)" ;;
    esac
done
export ASSUME_YES

step "Integracao SSO Vaultwarden <-> Keycloak - checagens de pre-voo"
docker inspect keycloak_server >/dev/null 2>&1 || die "keycloak_server nao esta rodando - rode ./deploy.sh primeiro"
STATUS="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}sem-healthcheck{{end}}' keycloak_server 2>/dev/null || echo ausente)"
[ "$STATUS" = "healthy" ] || [ "$STATUS" = "sem-healthcheck" ] || die "keycloak_server nao esta healthy (status: ${STATUS})"
log_ok "keycloak_server ativo"
[ -s secrets/kc_admin_password.txt ] || die "secrets/kc_admin_password.txt ausente - rode ./setup.sh primeiro"
[ -f .env ] || die ".env nao encontrado - rode ./setup.sh primeiro"

# shellcheck disable=SC1091
set -a && source .env && set +a

# -----------------------------------------------------------------------------
step "Dados da integracao (Enter mantem o valor atual/padrao)"
# -----------------------------------------------------------------------------
# Extrai o realm de dentro de VAULTWARDEN_SSO_AUTHORITY se ja estiver
# preenchido (".../realms/<realm>"), senao cai no padrao desta stack.
DEFAULT_REALM="prefeitura"
if [ -n "${VAULTWARDEN_SSO_AUTHORITY:-}" ] && [[ "$VAULTWARDEN_SSO_AUTHORITY" == */realms/* ]]; then
    DEFAULT_REALM="${VAULTWARDEN_SSO_AUTHORITY##*/realms/}"
fi

REALM_V=$(ask "Realm do Keycloak" "$DEFAULT_REALM")
CLIENT_ID_V=$(ask "Client ID do Vaultwarden no Keycloak" "${VAULTWARDEN_SSO_CLIENT_ID:-vaultwarden}")

if [ -z "${VAULTWARDEN_DOMAIN:-}" ]; then
    log_warn "VAULTWARDEN_DOMAIN esta vazio no .env - obrigatorio pro Vaultwarden nem subir (ver docs/06-vaultwarden.md)"
    VAULTWARDEN_DOMAIN=$(ask "URL publica do Vaultwarden (https://...)" "")
    [ -n "$VAULTWARDEN_DOMAIN" ] || die "URL vazia - cancelado. Preencha VAULTWARDEN_DOMAIN no .env e rode de novo"
fi

DEFAULT_AUTHORITY="${VAULTWARDEN_SSO_AUTHORITY:-${KC_HOSTNAME:-}/realms/${REALM_V}}"
AUTHORITY_V=$(ask "URL publica do realm no Keycloak (a mesma que o navegador acessa)" "$DEFAULT_AUTHORITY")

REDIRECT_URI="${VAULTWARDEN_DOMAIN%/}/identity/connect/oidc-signin"
WEB_ORIGIN="${VAULTWARDEN_DOMAIN%/}"

# -----------------------------------------------------------------------------
step "Autenticando no Keycloak (kcadm.sh)"
# -----------------------------------------------------------------------------
KC_ADMIN_USER="$(grep -E '^KC_BOOTSTRAP_ADMIN_USERNAME=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
KC_ADMIN_USER="${KC_ADMIN_USER:-kc_admin}"
KC_ADMIN_PW="$(cat secrets/kc_admin_password.txt)"

kcadm() {
    docker exec -i keycloak_server /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm-vw.config
}

if ! docker exec -i keycloak_server /opt/keycloak/bin/kcadm.sh config credentials \
        --config /tmp/kcadm-vw.config --server http://localhost:8080 \
        --realm master --user "$KC_ADMIN_USER" --password "$KC_ADMIN_PW" >/dev/null; then
    die "Falha ao autenticar no Keycloak - confira secrets/kc_admin_password.txt"
fi
log_ok "Autenticado como ${KC_ADMIN_USER}"

# -----------------------------------------------------------------------------
step "Realm '${REALM_V}'"
# -----------------------------------------------------------------------------
if kcadm get "realms/${REALM_V}" >/dev/null 2>&1; then
    log_ok "Realm '${REALM_V}' ja existe"
else
    log_warn "Realm '${REALM_V}' nao existe ainda"
    confirm "Criar o realm '${REALM_V}' agora (vazio, sem grupos/clients)?" "S" \
        || die "Cancelado - crie o realm primeiro (docs/02-configuracao-keycloak.md)"
    kcadm create realms -s "realm=${REALM_V}" -s enabled=true >/dev/null
    log_ok "Realm '${REALM_V}' criado"
fi

# -----------------------------------------------------------------------------
step "Client OIDC '${CLIENT_ID_V}'"
# -----------------------------------------------------------------------------
CLIENT_UUID="$(kcadm get clients -r "$REALM_V" -q "clientId=${CLIENT_ID_V}" \
    --fields id --format csv --noquotes 2>/dev/null | head -1)"

CLIENT_ARGS=(
    -s "clientId=${CLIENT_ID_V}"
    -s "protocol=openid-connect"
    -s "enabled=true"
    -s "publicClient=false"
    -s "standardFlowEnabled=true"
    -s "directAccessGrantsEnabled=false"
    -s "redirectUris=[\"${REDIRECT_URI}\"]"
    -s "webOrigins=[\"${WEB_ORIGIN}\"]"
)

if [ -n "$CLIENT_UUID" ]; then
    kcadm update "clients/${CLIENT_UUID}" -r "$REALM_V" "${CLIENT_ARGS[@]}" >/dev/null
    log_ok "Client '${CLIENT_ID_V}' ja existia (id ${CLIENT_UUID}) - redirect URI/web origin atualizados"
else
    CLIENT_UUID="$(kcadm create clients -r "$REALM_V" "${CLIENT_ARGS[@]}" -i)"
    log_ok "Client '${CLIENT_ID_V}' criado (id ${CLIENT_UUID})"
fi

# -----------------------------------------------------------------------------
step "Client secret"
# -----------------------------------------------------------------------------
SECRET_V=""
GET_AUTO=1
if [ "${ASSUME_YES:-0}" != "1" ]; then
    confirm "Buscar o secret automaticamente no Keycloak (recomendado - evita erro de copiar/colar)?" "S" || GET_AUTO=0
fi

if [ "$GET_AUTO" = "1" ]; then
    SECRET_JSON="$(kcadm get "clients/${CLIENT_UUID}/client-secret" -r "$REALM_V" 2>/dev/null || true)"
    SECRET_V="$(printf '%s' "$SECRET_JSON" | grep -o '"value" *: *"[^"]*"' | sed -E 's/.*"value" *: *"([^"]*)"/\1/')"
    if [ -z "$SECRET_V" ]; then
        log_warn "Nao consegui buscar o secret automaticamente - informe manualmente"
    else
        log_ok "Secret obtido direto do Keycloak (sem copiar/colar)"
    fi
fi

if [ -z "$SECRET_V" ]; then
    SECRET_V=$(ask_secret "Cole o client secret (aba Credentials do client, no Admin Console)")
    [ -n "$SECRET_V" ] || die "Secret vazio - cancelado"
fi

printf '%s' "$SECRET_V" > secrets/vw_sso_client_secret.txt
if chgrp 0 secrets/vw_sso_client_secret.txt 2>/dev/null; then
    chmod 640 secrets/vw_sso_client_secret.txt
else
    chmod 600 secrets/vw_sso_client_secret.txt
fi
log_ok "Secret gravado em secrets/vw_sso_client_secret.txt"

# -----------------------------------------------------------------------------
step "Atualizando .env"
# -----------------------------------------------------------------------------
set_env_var() {
    local key="$1" value="$2" escaped
    escaped="$(printf '%s' "$value" | sed -e 's/[&|\]/\\&/g')"
    if grep -qE "^${key}=" .env 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${escaped}|" .env
    else
        printf '%s=%s\n' "$key" "$value" >> .env
    fi
}

set_env_var "VAULTWARDEN_SSO_ENABLED" "true"
set_env_var "VAULTWARDEN_SSO_AUTHORITY" "$AUTHORITY_V"
set_env_var "VAULTWARDEN_SSO_CLIENT_ID" "$CLIENT_ID_V"
log_ok ".env atualizado (VAULTWARDEN_SSO_ENABLED=true, VAULTWARDEN_SSO_AUTHORITY, VAULTWARDEN_SSO_CLIENT_ID)"

# -----------------------------------------------------------------------------
step "Recriando o Vaultwarden com a nova configuracao"
# -----------------------------------------------------------------------------
if portainer_enabled 2>/dev/null; then
    export COMPOSE_PROFILES=portainer
fi
docker compose up -d --force-recreate vaultwarden >/dev/null

WAITED=0
VW_STATUS=""
while (( WAITED < 60 )); do
    VW_STATUS="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}sem-healthcheck{{end}}' vaultwarden 2>/dev/null || echo ausente)"
    case "$VW_STATUS" in
        healthy|sem-healthcheck) break ;;
        unhealthy) break ;;
    esac
    sleep 3
    WAITED=$((WAITED + 3))
done

if [ "$VW_STATUS" = "healthy" ] || [ "$VW_STATUS" = "sem-healthcheck" ]; then
    log_ok "vaultwarden -> ${VW_STATUS}"
else
    log_err "vaultwarden -> ${VW_STATUS} (confira 'docker compose logs vaultwarden')"
fi

print_panel "SSO VAULTWARDEN <-> KEYCLOAK CONFIGURADO" \
    "Realm: ${REALM_V}   Client ID: ${CLIENT_ID_V}" \
    "Authority: ${AUTHORITY_V}" \
    "" \
    "URLs registradas no client do Keycloak (confira se baterem):" \
    "  Redirect URI: ${REDIRECT_URI}" \
    "  Web origin:   ${WEB_ORIGIN}" \
    "" \
    "Testar: acesse ${VAULTWARDEN_DOMAIN} -> \"Enterprise Single Sign-On\"" \
    "Painel admin do Vaultwarden: ${VAULTWARDEN_DOMAIN%/}/admin (token em secrets/vw_admin_token.txt)" \
    "Detalhes: docs/06-vaultwarden.md#sso"

printf "\n%sIntegracao SSO concluida.%s\n\n" "${C_BGREEN}" "${C_RESET}"
