#!/usr/bin/env bash
# =============================================================================
# configure_ldap.sh - Federacao com o Active Directory via LDAPS
# (docs/03-federacao-ad.md), automatizada via kcadm.sh (CLI admin do
# proprio Keycloak).
#
# Idempotente: se o provider LDAP e o mapper de grupo ja existirem (mesmo
# nome), atualiza em vez de duplicar. Pode ser chamado direto ou via
# "./deploy.sh --configure-ldap" (que so' roda depois da stack subir).
#
# Pre-requisito: keycloak_server rodando e saudavel (rode ./deploy.sh antes).
#
# Uso:
#   ./scripts/configure_ldap.sh              interativo
#   ./scripts/configure_ldap.sh --yes        aceita os padroes sem perguntar
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
            echo "Uso: ./scripts/configure_ldap.sh [--yes]"
            exit 0
            ;;
        *) die "Argumento desconhecido: $arg (use --help)" ;;
    esac
done
export ASSUME_YES

step "Federacao LDAP/AD - checagens de pre-voo"
docker inspect keycloak_server >/dev/null 2>&1 || die "keycloak_server nao esta rodando - rode ./deploy.sh primeiro"
STATUS="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}sem-healthcheck{{end}}' keycloak_server 2>/dev/null || echo ausente)"
[ "$STATUS" = "healthy" ] || [ "$STATUS" = "sem-healthcheck" ] || die "keycloak_server nao esta healthy (status: ${STATUS})"
log_ok "keycloak_server ativo"

[ -s secrets/kc_admin_password.txt ] || die "secrets/kc_admin_password.txt ausente - rode ./setup.sh primeiro"

if [ -s certs/ad-ca.pem ]; then
    log_ok "certs/ad-ca.pem presente (truststore para LDAPS)"
else
    log_warn "certs/ad-ca.pem ausente - conexoes ldaps:// vao falhar com erro de certificado (PKIX)"
    log_warn "copie a CA do AD para certs/ad-ca.pem e rode: docker compose restart keycloak"
    confirm "Continuar mesmo assim?" "N" || die "Cancelado - copie a CA do AD primeiro"
fi

# shellcheck disable=SC1091
[ -f .env ] && set -a && source .env && set +a

# -----------------------------------------------------------------------------
step "Dados da federacao"
# -----------------------------------------------------------------------------
DEFAULT_DC=""
if [ -n "${AD_DOMAIN:-}" ]; then
    DEFAULT_DC="DC=${AD_DOMAIN//./,DC=}"
fi

REALM_V=$(ask "Realm do Keycloak" "prefeitura")
PROVIDER_NAME_V=$(ask "Nome do provider LDAP (identificador interno)" "ldap-ad")
LDAP_URL_V=$(ask "Connection URL do AD" "ldaps://${AD_DC_HOSTNAME:-dc01.rondonopolis.local}:636")
BIND_DN_V=$(ask "Bind DN (conta de servico, somente leitura)" "CN=svc-keycloak,OU=ServiceAccounts,${DEFAULT_DC:-DC=rondonopolis,DC=local}")
USERS_DN_V=$(ask "Users DN (onde estao as contas dos servidores)" "OU=Usuarios,${DEFAULT_DC:-DC=rondonopolis,DC=local}")
GROUPS_DN_V=$(ask "Groups DN (onde estao os grupos)" "OU=Grupos,${DEFAULT_DC:-DC=rondonopolis,DC=local}")

BIND_PW_FILE="secrets/ldap_bind_password.txt"
if [ -s "$BIND_PW_FILE" ]; then
    log_info "Senha da conta de bind ja existe em ${BIND_PW_FILE} - mantendo (apague o arquivo para trocar)"
else
    BIND_PW_V=$(ask_secret "Senha da conta de bind (${BIND_DN_V})")
    [ -n "$BIND_PW_V" ] || die "Senha vazia - cancelado"
    printf '%s' "$BIND_PW_V" > "$BIND_PW_FILE"
    chmod 600 "$BIND_PW_FILE"
    log_ok "Senha de bind gravada em ${BIND_PW_FILE} (600)"
fi
BIND_CREDENTIAL_V="$(cat "$BIND_PW_FILE")"

# -----------------------------------------------------------------------------
step "Autenticando no Keycloak (kcadm.sh)"
# -----------------------------------------------------------------------------
KC_ADMIN_USER="$(grep -E '^KC_BOOTSTRAP_ADMIN_USERNAME=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
KC_ADMIN_USER="${KC_ADMIN_USER:-kc_admin}"
KC_ADMIN_PW="$(cat secrets/kc_admin_password.txt)"

kcadm() {
    docker exec -i keycloak_server /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm.config
}

if ! docker exec -i keycloak_server /opt/keycloak/bin/kcadm.sh config credentials \
        --config /tmp/kcadm.config --server http://localhost:8080 \
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
    kcadm create realms -s "realm=${REALM_V}" -s enabled=true >/dev/null
    log_ok "Realm '${REALM_V}' criado"
    log_warn "Realm novo - grupos/clients da Etapa 2 (docs/02-configuracao-keycloak.md) ainda precisam ser criados a parte"
fi

# -----------------------------------------------------------------------------
step "Provider LDAP '${PROVIDER_NAME_V}'"
# -----------------------------------------------------------------------------
EXISTING_ID="$(kcadm get components -r "$REALM_V" -q type=org.keycloak.storage.UserStorageProvider \
    --fields id,name --format csv --noquotes 2>/dev/null \
    | awk -F, -v n="$PROVIDER_NAME_V" '$2==n {print $1}')"

LDAP_ARGS=(
    -s "providerId=ldap"
    -s "providerType=org.keycloak.storage.UserStorageProvider"
    -s "config.enabled=[\"true\"]"
    -s "config.vendor=[\"ad\"]"
    -s "config.connectionUrl=[\"${LDAP_URL_V}\"]"
    -s "config.usersDn=[\"${USERS_DN_V}\"]"
    -s "config.bindDn=[\"${BIND_DN_V}\"]"
    -s "config.bindCredential=[\"${BIND_CREDENTIAL_V}\"]"
    -s "config.editMode=[\"READ_ONLY\"]"
    -s "config.authType=[\"simple\"]"
    -s "config.usernameLDAPAttribute=[\"sAMAccountName\"]"
    -s "config.rdnLDAPAttribute=[\"cn\"]"
    -s "config.uuidLDAPAttribute=[\"objectGUID\"]"
    -s "config.userObjectClasses=[\"person, organizationalPerson, user\"]"
    -s "config.syncRegistrations=[\"false\"]"
    -s "config.trustEmail=[\"false\"]"
    -s "config.useTruststoreSpi=[\"ldapsOnly\"]"
    -s "config.connectionPooling=[\"true\"]"
    -s "config.pagination=[\"true\"]"
)

if [ -n "$EXISTING_ID" ]; then
    kcadm update "components/${EXISTING_ID}" -r "$REALM_V" "${LDAP_ARGS[@]}" >/dev/null
    PROVIDER_ID="$EXISTING_ID"
    log_ok "Provider '${PROVIDER_NAME_V}' ja existia - configuracao atualizada (id ${PROVIDER_ID})"
else
    PROVIDER_ID="$(kcadm create components -r "$REALM_V" -s "name=${PROVIDER_NAME_V}" "${LDAP_ARGS[@]}" -i)"
    log_ok "Provider '${PROVIDER_NAME_V}' criado (id ${PROVIDER_ID})"
fi

# -----------------------------------------------------------------------------
step "Mapper de grupos"
# -----------------------------------------------------------------------------
EXISTING_MAPPER_ID="$(kcadm get components -r "$REALM_V" -q "parent=${PROVIDER_ID}" \
    --fields id,name --format csv --noquotes 2>/dev/null \
    | awk -F, '$2=="group-ldap-mapper" {print $1}')"

MAPPER_ARGS=(
    -s "providerId=group-ldap-mapper"
    -s "providerType=org.keycloak.storage.ldap.mappers.LDAPStorageMapper"
    -s "parentId=${PROVIDER_ID}"
    -s "config.\"groups.dn\"=[\"${GROUPS_DN_V}\"]"
    -s "config.\"group.name.ldap.attribute\"=[\"cn\"]"
    -s "config.\"group.object.classes\"=[\"group\"]"
    -s "config.\"membership.ldap.attribute\"=[\"member\"]"
    -s "config.\"membership.attribute.type\"=[\"DN\"]"
    -s "config.mode=[\"READ_ONLY\"]"
    -s "config.\"preserve.group.inheritance\"=[\"false\"]"
)

if [ -n "$EXISTING_MAPPER_ID" ]; then
    kcadm update "components/${EXISTING_MAPPER_ID}" -r "$REALM_V" "${MAPPER_ARGS[@]}" >/dev/null
    log_ok "group-ldap-mapper ja existia - atualizado"
else
    kcadm create components -r "$REALM_V" -s "name=group-ldap-mapper" "${MAPPER_ARGS[@]}" >/dev/null
    log_ok "group-ldap-mapper criado (aponta para ${GROUPS_DN_V})"
fi

# -----------------------------------------------------------------------------
step "Sincronizando usuarios (Synchronize all users)"
# -----------------------------------------------------------------------------
if kcadm create "user-storage/${PROVIDER_ID}/sync?action=triggerFullSync" -r "$REALM_V" >/dev/null 2>&1; then
    log_ok "Sync disparado com sucesso"
else
    log_err "Sync falhou - verifique Connection URL, Bind DN e a senha de bind"
    log_err "Causas comuns: CA do AD ausente em certs/ad-ca.pem, firewall bloqueando 636, credenciais erradas"
    die "Federacao criada mas o sync falhou - corrija e rode de novo (idempotente)"
fi

print_panel "FEDERACAO LDAP CONFIGURADA" \
    "Realm: ${REALM_V}" \
    "Provider: ${PROVIDER_NAME_V} (${LDAP_URL_V})" \
    "Users DN: ${USERS_DN_V}" \
    "Groups DN: ${GROUPS_DN_V}" \
    "" \
    "Confira em: Admin Console -> ${REALM_V} -> Users" \
    "Portoes de validacao completos: docs/03-federacao-ad.md"

printf "\n%sFederacao LDAP concluida.%s\n\n" "${C_BGREEN}" "${C_RESET}"
