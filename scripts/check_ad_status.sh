#!/usr/bin/env bash
# =============================================================================
# check_ad_status.sh - Verifica o status da federacao com o Active Directory
# (docs/03-federacao-ad.md): confere se o provider LDAP existe, mostra a
# configuracao (sem expor a senha de bind), testa a conexao de verdade
# (sync incremental) e mostra quantos usuarios/grupos vieram do AD.
#
# Uso:
#   ./scripts/check_ad_status.sh              # usa o realm "Prefeitura"
#   ./scripts/check_ad_status.sh <realm>       # outro realm
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=scripts/lib/theme.sh
source "scripts/lib/theme.sh"

REALM_V="${1:-Prefeitura}"

print_header "STATUS - Federacao com o Active Directory (realm: ${REALM_V})"

docker inspect keycloak_server >/dev/null 2>&1 || die "keycloak_server nao esta rodando - rode ./deploy.sh primeiro"
STATUS="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}sem-healthcheck{{end}}' keycloak_server 2>/dev/null || echo ausente)"
[ "$STATUS" = "healthy" ] || [ "$STATUS" = "sem-healthcheck" ] || die "keycloak_server nao esta healthy (status: ${STATUS})"
[ -s secrets/kc_admin_password.txt ] || die "secrets/kc_admin_password.txt ausente - rode ./setup.sh primeiro"

# -----------------------------------------------------------------------------
step "Autenticando no Keycloak (kcadm.sh)"
# -----------------------------------------------------------------------------
KC_ADMIN_USER="$(grep -E '^KC_BOOTSTRAP_ADMIN_USERNAME=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
KC_ADMIN_USER="${KC_ADMIN_USER:-kc_admin}"
KC_ADMIN_PW="$(cat secrets/kc_admin_password.txt)"

kcadm() {
    docker exec -i keycloak_server /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm-ad-check.config
}

if ! docker exec -i keycloak_server /opt/keycloak/bin/kcadm.sh config credentials \
        --config /tmp/kcadm-ad-check.config --server http://localhost:8080 \
        --realm master --user "$KC_ADMIN_USER" --password "$KC_ADMIN_PW" >/dev/null 2>&1; then
    die "Falha ao autenticar no Keycloak - confira secrets/kc_admin_password.txt"
fi
log_ok "Autenticado como ${KC_ADMIN_USER}"

if ! kcadm get "realms/${REALM_V}" >/dev/null 2>&1; then
    die "Realm '${REALM_V}' nao existe no Keycloak - confira o nome (docs/02-configuracao-keycloak.md)"
fi

# -----------------------------------------------------------------------------
step "Provider LDAP"
# -----------------------------------------------------------------------------
PROVIDER_CSV="$(kcadm get components -r "$REALM_V" -q type=org.keycloak.storage.UserStorageProvider \
    --fields id,name --format csv --noquotes 2>/dev/null)"

if [ -z "$PROVIDER_CSV" ]; then
    print_panel "AD NAO CONFIGURADO" \
        "Nenhum provider LDAP encontrado no realm '${REALM_V}'." \
        "Configure com: ./manage.sh -> Configurar LDAP/AD" \
        "ou ./scripts/configure_ldap.sh (docs/03-federacao-ad.md)"
    exit 1
fi

PROVIDER_ID="$(echo "$PROVIDER_CSV" | head -1 | cut -d, -f1)"
PROVIDER_NAME="$(echo "$PROVIDER_CSV" | head -1 | cut -d, -f2)"
log_ok "Provider '${PROVIDER_NAME}' encontrado (id ${PROVIDER_ID})"

CONFIG_JSON="$(kcadm get "components/${PROVIDER_ID}" -r "$REALM_V" 2>/dev/null)"
get_field() {
    # extrai config.<campo>[0] de um JSON de component do kcadm (sem jq)
    printf '%s' "$CONFIG_JSON" | grep -o "\"$1\" *: *\[ *\"[^\"]*\"" | head -1 | sed -E 's/.*\[ *"([^"]*)"/\1/'
}

CONN_URL="$(get_field connectionUrl)"
USERS_DN="$(get_field usersDn)"
BIND_DN="$(get_field bindDn)"
VENDOR="$(get_field vendor)"
ENABLED="$(get_field enabled)"

print_panel "CONFIGURACAO ATUAL" \
    "Connection URL: ${CONN_URL:-?}" \
    "Vendor: ${VENDOR:-?}   Habilitado: ${ENABLED:-?}" \
    "Bind DN: ${BIND_DN:-?}" \
    "Users DN: ${USERS_DN:-?}"
log_info "Senha de bind NAO exibida por seguranca (secrets/ldap_bind_password.txt)"

# -----------------------------------------------------------------------------
step "Mapper de grupos"
# -----------------------------------------------------------------------------
MAPPER_CSV="$(kcadm get components -r "$REALM_V" -q "parent=${PROVIDER_ID}" \
    --fields id,name --format csv --noquotes 2>/dev/null | grep 'group-ldap-mapper' || true)"
if [ -n "$MAPPER_CSV" ]; then
    log_ok "group-ldap-mapper configurado"
else
    log_warn "group-ldap-mapper nao encontrado - grupos do AD podem nao estar sincronizando"
fi

# -----------------------------------------------------------------------------
step "Teste de conexao real (bind LDAP sincrono)"
# -----------------------------------------------------------------------------
# Achado real testando este script: "triggerFullSync"/"triggerChangedUsersSync"
# so' ENFILEIRA o sync e retorna sucesso na hora - o erro de conexao de
# verdade (host inalcancavel, credencial errada) so' aparece depois, nos
# logs do Keycloak, de forma assincrona. Isso dava falso positivo ("OK")
# mesmo contra um AD totalmente inalcancavel. O endpoint testLDAPConnection
# (o mesmo que o botao "Test authentication" do Admin Console usa) e'
# sincrono de verdade: testa TCP + bind LDAP e so' retorna depois de saber
# se funcionou.
CONN_OK=0
if [ -s secrets/ldap_bind_password.txt ]; then
    BIND_PW="$(cat secrets/ldap_bind_password.txt)"
    TEST_RESULT="$(kcadm create testLDAPConnection -r "$REALM_V" \
        -s action=testAuthentication \
        -s "connectionUrl=${CONN_URL}" \
        -s "bindDn=${BIND_DN}" \
        -s "bindCredential=${BIND_PW}" \
        -s "useTruststoreSpi=ldapsOnly" \
        -s "authType=simple" \
        -s "connectionTimeout=" 2>&1)"
    TEST_EXIT=$?
    if [ "$TEST_EXIT" = "0" ]; then
        log_ok "Bind LDAP sincrono OK - conexao e credenciais confirmadas agora mesmo"
        CONN_OK=1
    else
        log_err "Bind LDAP falhou: ${TEST_RESULT:-<sem detalhe>}"
        log_err "Causas comuns: certs/ad-ca.pem ausente/errado, firewall bloqueando 636, credenciais de bind erradas, DNS nao resolve o host"
    fi
else
    log_warn "secrets/ldap_bind_password.txt ausente - nao da pra testar o bind de verdade"
    log_warn "(provider foi configurado por fora deste script/senha foi apagada - teste manualmente pelo Admin Console)"
fi

# -----------------------------------------------------------------------------
step "Usuarios e grupos sincronizados"
# -----------------------------------------------------------------------------
USER_COUNT="$(kcadm get users/count -r "$REALM_V" 2>/dev/null)"
USER_COUNT="${USER_COUNT:-?}"
GROUP_COUNT="$(kcadm get groups -r "$REALM_V" --fields id --format csv --noquotes 2>/dev/null | grep -c .)"
GROUP_COUNT="${GROUP_COUNT:-0}"
log_info "Usuarios no realm: ${USER_COUNT}   Grupos no realm: ${GROUP_COUNT}"
log_info "(inclui usuarios/grupos locais, se houver algum fora do AD; numero so' atualiza apos um sync)"

echo
if [ "$CONN_OK" = "1" ]; then
    print_panel "FEDERACAO COM O AD: OK" \
        "Provider '${PROVIDER_NAME}' conectado, ${USER_COUNT} usuario(s) no realm." \
        "Detalhes: docs/03-federacao-ad.md"
else
    print_panel "FEDERACAO COM O AD: COM PROBLEMA" \
        "Bind LDAP falhou no teste sincrono - veja o erro acima." \
        "Detalhes: docs/03-federacao-ad.md"
    exit 1
fi
