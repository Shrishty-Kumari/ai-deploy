#!/usr/bin/env bash
# Dumps the Postgres database to a timestamped, gzip-compressed file and
# deletes backups older than 7 days. Intended to run via cron.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a; source .env; set +a

BACKUP_DIR="${BACKUP_DIR:-$HOME/backups}"
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FILENAME="${BACKUP_DIR}/${POSTGRES_DB}_${TIMESTAMP}.sql.gz"

mkdir -p "$BACKUP_DIR"

echo "[backup] Dumping ${POSTGRES_DB} -> ${FILENAME}"
docker compose exec -T postgres pg_dump -U "$POSTGRES_USER" "$POSTGRES_DB" | gzip > "$FILENAME"

echo "[backup] Removing backups older than 7 days"
find "$BACKUP_DIR" -name "*.sql.gz" -mtime +7 -delete

echo "[backup] Done. Current backups:"
ls -lh "$BACKUP_DIR"
