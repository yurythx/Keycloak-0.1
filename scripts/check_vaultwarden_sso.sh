#!/usr/bin/env bash
# =============================================================================
# check_vaultwarden_sso.sh - Verifica o status real da integracao SSO
# Vaultwarden <-> Keycloak (nao so' confere config, testa o fluxo de
# verdade: pede pro Vaultwarden iniciar um login OIDC e confirma que ele
# recebe de volta um redirect valido do Keycloak, com PKCE).
#
# Uso:
#   ./scripts/check_vaultwarden_sso.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=scripts/lib/theme.sh
source "scripts/lib/theme.sh"

[ -f .env ] || die ".env nao encontrado - rode ./setup.sh primeiro"
# shellcheck disable=SC1091
set -a && source .env && set +a

print_header "STATUS - Integracao Vaultwarden <-> Keycloak"

FAILED=0

# -----------------------------------------------------------------------------
step "1) Configuracao no .env"
# -----------------------------------------------------------------------------
if [ "${VAULTWARDEN_SSO_ENABLED:-false}" = "true" ]; then
    log_ok "VAULTWARDEN_SSO_ENABLED=true"
else
    log_err "VAULTWARDEN_SSO_ENABLED=${VAULTWARDEN_SSO_ENABLED:-<vazio>} - SSO desligado"
    log_info "Ligar com: ./manage.sh -> Configurar SSO do Vaultwarden"
    FAILED=1
fi
log_info "Authority=${VAULTWARDEN_SSO_AUTHORITY:-<vazio>}  Client ID=${VAULTWARDEN_SSO_CLIENT_ID:-<vazio>}"

if [ -s secrets/vw_sso_client_secret.txt ]; then
    log_ok "secrets/vw_sso_client_secret.txt presente e nao-vazio"
else
    log_err "secrets/vw_sso_client_secret.txt ausente ou vazio"
    FAILED=1
fi

# -----------------------------------------------------------------------------
step "2) Contêineres"
# -----------------------------------------------------------------------------
for c in keycloak_server vaultwarden; do
    st="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$c" 2>/dev/null || echo ausente)"
    if [ "$st" = "healthy" ] || [ "$st" = "running" ]; then
        log_ok "${c}: ${st}"
    else
        log_err "${c}: ${st}"
        FAILED=1
    fi
done

if [ "$FAILED" = "1" ]; then
    print_panel "INTEGRACAO NAO ESTA PRONTA" \
        "Resolva os itens marcados [XX] acima antes de testar o fluxo de login." \
        "Ver docs/06-vaultwarden.md#sso para o passo a passo completo."
    exit 1
fi

# -----------------------------------------------------------------------------
step "3) Vaultwarden alcanca a URL publica localmente"
# -----------------------------------------------------------------------------
VW_CHECK_HOST="${VAULTWARDEN_BIND:-0.0.0.0}"
[ "$VW_CHECK_HOST" = "0.0.0.0" ] && VW_CHECK_HOST="127.0.0.1"
VW_PORT="${VAULTWARDEN_HTTP_PORT:-8081}"

if ! curl -s --max-time 5 -o /dev/null -w '' "http://${VW_CHECK_HOST}:${VW_PORT}/alive" 2>/dev/null; then
    log_err "Vaultwarden nao respondeu em http://${VW_CHECK_HOST}:${VW_PORT}/alive"
    exit 1
fi
log_ok "Vaultwarden respondendo localmente"

# -----------------------------------------------------------------------------
step "4) Fluxo real de login SSO (redirect com PKCE)"
# -----------------------------------------------------------------------------
if ! command -v openssl >/dev/null 2>&1; then
    log_warn "openssl ausente - pulando o teste de fluxo real (PKCE nao pode ser gerado)"
else
    CODE_VERIFIER="$(openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 64)"
    CODE_CHALLENGE="$(printf '%s' "$CODE_VERIFIER" | openssl dgst -sha256 -binary | openssl base64 -A | tr '+/' '-_' | tr -d '=')"

    LOCATION="$(curl -s -D - -o /dev/null --max-time 10 \
        "http://${VW_CHECK_HOST}:${VW_PORT}/identity/connect/authorize?client_id=web&redirect_uri=http://localhost/sso-connector.html&response_type=code&scope=openid&state=check&code_challenge=${CODE_CHALLENGE}&code_challenge_method=S256&domain_hint=vaultwarden" \
        2>/dev/null | grep -i '^location:' | sed 's/[Ll]ocation: //' | tr -d '\r')"

    if [ -z "$LOCATION" ]; then
        log_err "Vaultwarden nao redirecionou pro Keycloak - confira 'docker compose logs vaultwarden'"
        FAILED=1
    elif echo "$LOCATION" | grep -q "error="; then
        log_err "Keycloak/Vaultwarden retornou erro no redirect:"
        printf "        %s\n" "$LOCATION"
        FAILED=1
    elif echo "$LOCATION" | grep -q "client_id=${VAULTWARDEN_SSO_CLIENT_ID:-vaultwarden}"; then
        log_ok "Redirect valido pro Keycloak, com client_id e PKCE corretos"
        log_info "$(echo "$LOCATION" | cut -c1-100)..."
    else
        log_warn "Redirect aconteceu mas nao bate com o client_id esperado - confira manualmente:"
        printf "        %s\n" "$LOCATION"
    fi
fi

echo
if [ "$FAILED" = "1" ]; then
    print_panel "INTEGRACAO COM PROBLEMAS" \
        "Veja os itens [XX]/[!!] acima. docs/06-vaultwarden.md#sso tem o passo a passo."
    exit 1
else
    print_panel "INTEGRACAO OK" \
        "Vaultwarden inicia o login, redireciona pro Keycloak certo, com PKCE." \
        "Isso NAO substitui um login real de ponta a ponta pelo navegador -" \
        "faca esse teste manual pelo menos uma vez (${VAULTWARDEN_DOMAIN:-<VAULTWARDEN_DOMAIN>})."
fi
