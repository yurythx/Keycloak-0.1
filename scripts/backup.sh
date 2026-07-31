#!/bin/bash
# Backup logico diario dos bancos desta stack (Keycloak e Vaultwarden) +
# backup do volume de dados do Vaultwarden (rsa_key.pem, anexos, sends,
# cache de icones - sem a chave RSA, os "sends" e alguns dados cifrados
# ficam irrecuperaveis mesmo com o banco intacto).
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
VW_POSTGRES_DB="${VW_POSTGRES_DB:-vaultwarden}"
VW_POSTGRES_USER="${VW_POSTGRES_USER:-vw_user}"

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

FAILED=0

# dump_db <label> <service> <db> <user>
dump_db() {
    local label="$1" service="$2" db="$3" user="$4"
    local out="${BACKUP_DIR}/${label}_${DATE}.sql.gz"
    local tmp="${out}.part"

    echo "[$(date '+%F %T')] Iniciando backup de '${db}' (${label}) -> ${out}"
    if docker compose exec -T "$service" pg_dump -U "$user" "$db" | gzip > "$tmp"; then
        mv "$tmp" "$out"
        echo "[$(date '+%F %T')] Backup concluido: ${out} ($(du -h "$out" | cut -f1))"
    else
        rm -f "$tmp"
        echo "[$(date '+%F %T')] ERRO: falha ao gerar o backup de '${db}' (${label})" >&2
        FAILED=1
    fi
}

dump_db "keycloak" postgres "$POSTGRES_DB" "$POSTGRES_USER"
dump_db "vaultwarden" vaultwarden-db "$VW_POSTGRES_DB" "$VW_POSTGRES_USER"

# Volume de dados do Vaultwarden (nao e' so' o banco - rsa_key.pem, anexos,
# sends e cache de icones vivem em /data dentro do container, fora do
# Postgres). Sem a rsa_key.pem, alguns dados cifrados ficam irrecuperaveis
# mesmo restaurando o dump do banco corretamente.
VW_DATA_OUT="${BACKUP_DIR}/vaultwarden_data_${DATE}.tar.gz"
VW_DATA_TMP="${VW_DATA_OUT}.part"
echo "[$(date '+%F %T')] Iniciando backup do volume de dados do Vaultwarden -> ${VW_DATA_OUT}"
if docker compose exec -T vaultwarden tar czf - -C /data . > "$VW_DATA_TMP" 2>/dev/null; then
    mv "$VW_DATA_TMP" "$VW_DATA_OUT"
    echo "[$(date '+%F %T')] Backup concluido: ${VW_DATA_OUT} ($(du -h "$VW_DATA_OUT" | cut -f1))"
else
    rm -f "$VW_DATA_TMP"
    echo "[$(date '+%F %T')] ERRO: falha ao gerar o backup do volume de dados do Vaultwarden" >&2
    FAILED=1
fi

echo "[$(date '+%F %T')] Removendo backups com mais de ${RETENTION_DAYS} dias"
find "$BACKUP_DIR" \( -name 'keycloak_*.sql.gz' -o -name 'vaultwarden_*.sql.gz' -o -name 'vaultwarden_data_*.tar.gz' \) -mtime "+${RETENTION_DAYS}" -delete

if [ "$FAILED" = "1" ]; then
    echo "[$(date '+%F %T')] Backup finalizado COM FALHAS - veja os erros acima" >&2
    exit 1
fi

echo "[$(date '+%F %T')] Backup finalizado com sucesso"
