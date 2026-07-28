#!/bin/bash
# Backup logico diario do banco do Keycloak.
# Uso (cron, 02:00 todo dia):
#   0 2 * * * /opt/keycloak-stack/scripts/backup.sh >> /var/log/keycloak-backup.log 2>&1
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKUP_DIR="${BACKUP_DIR:-/mnt/backup_nfs}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
DATE="$(date +%Y%m%d_%H%M%S)"

cd "$STACK_DIR"
# shellcheck disable=SC1091
[ -f .env ] && source .env

POSTGRES_DB="${POSTGRES_DB:-keycloak}"
POSTGRES_USER="${POSTGRES_USER:-keycloak_user}"

mkdir -p "$BACKUP_DIR"

# Garante que o backup nao esta indo pro mesmo disco/particao da raiz do
# sistema (comparando o device ID via "stat -c %d") - se BACKUP_DIR nao
# for um armazenamento realmente separado (NFS, disco extra, etc.), o
# proposito do backup (sobreviver a um disco cheio/corrompido da VM) fica
# comprometido, e silenciosamente: o mkdir -p acima teria criado a pasta
# no disco local sem avisar nada. Comparar o device (nao so' checar se e'
# um "mountpoint") cobre tambem o caso de BACKUP_DIR ser uma subpasta
# dentro do ponto de montagem externo, nao so' a raiz exata dele.
ROOT_DEV="$(stat -c %d / 2>/dev/null || echo "")"
BACKUP_DEV="$(stat -c %d "$BACKUP_DIR" 2>/dev/null || echo "")"
if [ -n "$ROOT_DEV" ] && [ "$ROOT_DEV" = "$BACKUP_DEV" ]; then
    echo "[$(date '+%F %T')] AVISO: BACKUP_DIR (${BACKUP_DIR}) esta no mesmo disco da raiz do sistema - NAO e' armazenamento externo" >&2
    if [ "${REQUIRE_EXTERNAL_BACKUP:-1}" != "0" ]; then
        echo "[$(date '+%F %T')] ERRO: abortando para nao arriscar encher o disco da VM. Monte um armazenamento externo (NFS/disco separado) em ${BACKUP_DIR}, ou defina REQUIRE_EXTERNAL_BACKUP=0 para permitir backup local mesmo assim (NAO recomendado em producao)" >&2
        exit 1
    fi
fi

OUT_FILE="${BACKUP_DIR}/keycloak_${DATE}.sql.gz"
TMP_FILE="${OUT_FILE}.part"

echo "[$(date '+%F %T')] Iniciando backup de '${POSTGRES_DB}' -> ${OUT_FILE}"

if docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$TMP_FILE"; then
    mv "$TMP_FILE" "$OUT_FILE"
    echo "[$(date '+%F %T')] Backup concluido: ${OUT_FILE} ($(du -h "$OUT_FILE" | cut -f1))"
else
    rm -f "$TMP_FILE"
    echo "[$(date '+%F %T')] ERRO: falha ao gerar o backup" >&2
    exit 1
fi

echo "[$(date '+%F %T')] Removendo backups com mais de ${RETENTION_DAYS} dias"
find "$BACKUP_DIR" -name 'keycloak_*.sql.gz' -mtime "+${RETENTION_DAYS}" -delete

echo "[$(date '+%F %T')] Backup finalizado com sucesso"
