#!/usr/bin/env bash
# =============================================================================
# session_stats.sh - Sessoes ativas por realm/client, via Admin REST API
# do Keycloak (GET /admin/realms/{realm}/client-session-stats).
#
# Por que via API Admin e nao Prometheus: o /metrics nativo do Keycloak
# (KC_METRICS_ENABLED=true) expoe metricas de infraestrutura (JVM, pool
# de conexoes, tempo de resposta HTTP) mas NAO expoe contagem de sessoes
# ativas nem contadores dedicados de login/falha de login - isso viria de
# uma extensao SPI de terceiros (keycloak-metrics-spi), nao instalada
# aqui de proposito (risco de manutencao/compatibilidade com versoes
# novas do Keycloak). Este script cobre a lacuna sem depender de nada
# alem do proprio kcadm.sh, ja usado no resto do projeto. Ver
# docs/monitoramento.md para o mapeamento completo de metricas.
#
# Uso:
#   ./scripts/session_stats.sh                 tabela legivel, realm "prefeitura"
#   ./scripts/session_stats.sh <realm>          tabela legivel, outro realm
#   ./scripts/session_stats.sh <realm> --total  so' o numero total (Zabbix
#                                                UserParameter/external check)
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"
# shellcheck source=scripts/lib/theme.sh
source "scripts/lib/theme.sh"

REALM="prefeitura"
TOTAL_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --total) TOTAL_ONLY=1 ;;
        -h|--help)
            echo "Uso: ./scripts/session_stats.sh [realm] [--total]"
            exit 0
            ;;
        *) REALM="$arg" ;;
    esac
done

docker inspect keycloak_server >/dev/null 2>&1 || die "keycloak_server nao esta rodando"
[ -s secrets/kc_admin_password.txt ] || die "secrets/kc_admin_password.txt ausente - rode ./setup.sh primeiro"

KC_ADMIN_USER="$(grep -E '^KC_BOOTSTRAP_ADMIN_USERNAME=' .env 2>/dev/null | cut -d= -f2- | tr -d '\r')"
KC_ADMIN_USER="${KC_ADMIN_USER:-kc_admin}"
KC_ADMIN_PW="$(cat secrets/kc_admin_password.txt)"

if ! docker exec -i keycloak_server /opt/keycloak/bin/kcadm.sh config credentials \
        --config /tmp/session_stats_kcadm.config --server http://localhost:8080 \
        --realm master --user "$KC_ADMIN_USER" --password "$KC_ADMIN_PW" >/dev/null 2>&1; then
    die "Falha ao autenticar no Keycloak - confira secrets/kc_admin_password.txt"
fi

STATS_JSON="$(docker exec -i keycloak_server /opt/keycloak/bin/kcadm.sh get \
    "realms/${REALM}/client-session-stats" --config /tmp/session_stats_kcadm.config 2>&1)" \
    || die "Falha ao consultar client-session-stats do realm '${REALM}' (existe esse realm?): ${STATS_JSON}"

# Soma a coluna "active" de cada client, sem depender de jq (nao
# garantido estar instalado na VM) - a saida do kcadm e' JSON
# pretty-printed, uma chave por linha, formato estavel o suficiente pra
# grep/awk (mesma abordagem ja usada em outros scripts deste projeto).
TOTAL_ACTIVE="$(echo "$STATS_JSON" | grep '"active"' | grep -oE '[0-9]+' | awk '{s+=$1} END{print s+0}')"

if [ "$TOTAL_ONLY" = "1" ]; then
    printf '%s\n' "$TOTAL_ACTIVE"
    exit 0
fi

print_header "SESSOES ATIVAS - realm '${REALM}'"
printf "  %-30s %8s %8s\n" "CLIENT" "ATIVAS" "OFFLINE"
CLIENT_IDS="$(echo "$STATS_JSON" | grep '"clientId"' | sed -E 's/.*"clientId"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/')"
ACTIVES="$(echo "$STATS_JSON" | grep '"active"' | grep -oE '[0-9]+')"
OFFLINES="$(echo "$STATS_JSON" | grep '"offline"' | grep -oE '[0-9]+')"
paste -d'\t' <(printf '%s\n' "$CLIENT_IDS") <(printf '%s\n' "$ACTIVES") <(printf '%s\n' "$OFFLINES") \
    | awk -F'\t' '{printf "  %-30s %8s %8s\n", $1, $2, $3}'

log_ok "Total de sessoes ativas: ${TOTAL_ACTIVE}"
