#!/bin/bash
# Drill de restauracao (docs/05-golive-operacao.md): restaura um backup em um
# container Postgres descartavel e isolado, para validar a integridade
# da copia SEM tocar no banco de producao. Reconhece tanto os dumps do
# Keycloak quanto os do Vaultwarden (scripts/backup.sh gera os dois).
#
# Uso:
#   ./scripts/restore_test.sh                       # usa o dump mais recente (qualquer um) em $BACKUP_DIR
#   ./scripts/restore_test.sh /caminho/para/dump.sql.gz
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-/mnt/backup_nfs}"
TEST_CONTAINER="restore_test_db"
TEST_DB="restore_check"
TEST_USER="restore_check_user"
TEST_PASSWORD="restore-check-$(date +%s)"

cd "$STACK_DIR"

DUMP_FILE="${1:-}"
if [ -z "$DUMP_FILE" ]; then
    DUMP_FILE="$(find "${BACKUP_DIR}" -maxdepth 1 \( -name 'keycloak_*.sql.gz' -o -name 'vaultwarden_*.sql.gz' \) -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -n1 | cut -d' ' -f2- || true)"
fi
if [ -z "$DUMP_FILE" ] || [ ! -f "$DUMP_FILE" ]; then
    echo "ERRO: nenhum arquivo de backup encontrado (informe o caminho como argumento)" >&2
    exit 1
fi

case "$(basename "$DUMP_FILE")" in
    vaultwarden_*) LABEL="Vaultwarden" ;;
    keycloak_*) LABEL="Keycloak" ;;
    *) LABEL="desconhecido" ;;
esac

echo "[$(date '+%F %T')] Testando restauracao de: ${DUMP_FILE} (${LABEL})"

cleanup() {
    docker rm -f "$TEST_CONTAINER" >/dev/null 2>&1 || true
}
trap cleanup EXIT

docker run -d --name "$TEST_CONTAINER" \
    -e POSTGRES_DB="$TEST_DB" \
    -e POSTGRES_USER="$TEST_USER" \
    -e POSTGRES_PASSWORD="$TEST_PASSWORD" \
    postgres:16-alpine >/dev/null

echo "[$(date '+%F %T')] Aguardando container de teste ficar pronto..."
for _ in $(seq 1 30); do
    if docker exec "$TEST_CONTAINER" pg_isready -U "$TEST_USER" -d "$TEST_DB" >/dev/null 2>&1; then
        break
    fi
    sleep 2
done

echo "[$(date '+%F %T')] Restaurando dump no container de teste..."
if ! gunzip -c "$DUMP_FILE" | docker exec -i "$TEST_CONTAINER" psql -U "$TEST_USER" -d "$TEST_DB" >/tmp/restore_test_output.log 2>&1; then
    echo "ERRO: falha ao restaurar o dump. Veja /tmp/restore_test_output.log" >&2
    exit 1
fi

TABLE_COUNT="$(docker exec "$TEST_CONTAINER" psql -U "$TEST_USER" -d "$TEST_DB" -tAc \
    "SELECT count(*) FROM information_schema.tables WHERE table_schema='public'")"

echo "[$(date '+%F %T')] Tabelas restauradas: ${TABLE_COUNT}"

if [ "${TABLE_COUNT:-0}" -lt 1 ]; then
    echo "FALHA: dump restaurado nao contem tabelas - backup pode estar corrompido" >&2
    exit 1
fi

echo "[$(date '+%F %T')] PASS: restauracao do backup do ${LABEL} validada com sucesso (${TABLE_COUNT} tabelas)"
echo "[$(date '+%F %T')] Lembrete: isto testa so' o dump SQL. O backup do volume de dados do"
echo "  Vaultwarden (vaultwarden_data_*.tar.gz - rsa_key.pem, anexos, sends) nao e' um dump"
echo "  SQL e nao e' validado por este script - confira manualmente com 'tar tzf <arquivo>'."
