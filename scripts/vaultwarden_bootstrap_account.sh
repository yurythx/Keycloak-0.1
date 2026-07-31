#!/usr/bin/env bash
# =============================================================================
# vaultwarden_bootstrap_account.sh - Garante que a conta inicial do
# Vaultwarden (VAULTWARDEN_INITIAL_USER_EMAIL) existe, criando-a com
# senha ja definida se ainda nao existir. Chamado automaticamente pelo
# deploy.sh no final de todo deploy - IDEMPOTENTE: se a conta ja existe,
# nao faz nada (nunca sobrescreve a senha de uma conta existente, mesmo
# que a senha em secrets/vw_initial_user_password.txt mude depois).
#
# So funciona com o Vaultwarden ja saudavel. Pode ser chamado standalone:
#   ./scripts/vaultwarden_bootstrap_account.sh
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=scripts/lib/theme.sh
source "scripts/lib/theme.sh"

[ -f .env ] || die ".env nao encontrado - rode ./setup.sh primeiro"
# shellcheck disable=SC1091
set -a && source .env && set +a

EMAIL="${VAULTWARDEN_INITIAL_USER_EMAIL:-}"
NAME="${VAULTWARDEN_INITIAL_USER_NAME:-Suporte}"
PW_FILE="secrets/vw_initial_user_password.txt"

if [ -z "$EMAIL" ]; then
    log_info "VAULTWARDEN_INITIAL_USER_EMAIL vazio no .env - pulando criacao de conta inicial"
    exit 0
fi

if ! docker inspect vaultwarden >/dev/null 2>&1; then
    log_warn "vaultwarden nao esta rodando - pulando criacao de conta inicial (rode de novo apos o deploy)"
    exit 0
fi
VW_STATUS="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}sem-healthcheck{{end}}' vaultwarden 2>/dev/null || echo ausente)"
if [ "$VW_STATUS" != "healthy" ] && [ "$VW_STATUS" != "sem-healthcheck" ]; then
    log_warn "vaultwarden nao esta healthy (${VW_STATUS}) - pulando criacao de conta inicial"
    exit 0
fi

# -----------------------------------------------------------------------------
step "Conta inicial do Vaultwarden (${EMAIL})"
# -----------------------------------------------------------------------------
VW_DB_USER="${VW_POSTGRES_USER:-vw_user}"
VW_DB_NAME="${VW_POSTGRES_DB:-vaultwarden}"

EXISTING="$(docker compose exec -T vaultwarden-db psql -U "$VW_DB_USER" -d "$VW_DB_NAME" -tAc \
    "SELECT 1 FROM users WHERE email='${EMAIL}' LIMIT 1;" 2>/dev/null | tr -d '[:space:]')"

if [ "$EXISTING" = "1" ]; then
    log_ok "Conta '${EMAIL}' ja existe - nada a fazer (senha nunca e' sobrescrita automaticamente)"
    exit 0
fi

[ -s "$PW_FILE" ] || die "${PW_FILE} ausente/vazio - rode ./setup.sh primeiro"
command -v python3 >/dev/null 2>&1 || die "python3 nao encontrado - necessario pra criar a conta (pip install cryptography)"
python3 -c "import cryptography" 2>/dev/null || die "pacote 'cryptography' do Python ausente - rode: pip install cryptography"

log_info "Conta '${EMAIL}' nao existe ainda - provisionando (janela curta com autorregistro temporariamente ligado)"

OVERRIDE_FILE=".vw_signup_override.yml"
cat > "$OVERRIDE_FILE" <<'EOF'
services:
  vaultwarden:
    environment:
      SIGNUPS_ALLOWED: "true"
EOF

REVERTED=0
revert() {
    [ "$REVERTED" = "1" ] && return 0
    REVERTED=1
    docker compose -f docker-compose.yml up -d --force-recreate vaultwarden >/dev/null 2>&1
    rm -f "$OVERRIDE_FILE"
}
trap revert EXIT

if ! docker compose -f docker-compose.yml -f "$OVERRIDE_FILE" up -d --force-recreate vaultwarden >/dev/null 2>&1; then
    log_err "Falha ao ligar SIGNUPS_ALLOWED temporariamente"
    exit 1
fi

WAITED=0
while (( WAITED < 60 )); do
    ST="$(docker inspect --format='{{if .State.Health}}{{.State.Health.Status}}{{else}}sem-healthcheck{{end}}' vaultwarden 2>/dev/null || echo ausente)"
    [ "$ST" = "healthy" ] || [ "$ST" = "sem-healthcheck" ] && break
    sleep 2
    WAITED=$((WAITED + 2))
done

PASSWORD="$(cat "$PW_FILE")"
if python3 scripts/vaultwarden_create_user.py "${VAULTWARDEN_DOMAIN}" "$EMAIL" "$PASSWORD" "$NAME" >/tmp/vw_bootstrap_out.log 2>&1; then
    log_ok "Conta '${EMAIL}' criada com sucesso"
else
    log_err "Falha ao criar a conta - saida:"
    sed 's/^/        /' /tmp/vw_bootstrap_out.log
fi

revert
trap - EXIT
log_ok "SIGNUPS_ALLOWED revertido pro padrao (false)"
