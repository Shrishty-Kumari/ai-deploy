#!/usr/bin/env bash
# Restores a Postgres database from a .sql.gz backup produced by backup.sh
# Usage: ./scripts/restore.sh /path/to/backup.sql.gz
set -euo pipefail

if [ $# -ne 1 ]; then
  echo "Usage: $0 <backup_file.sql.gz>"
  exit 1
fi

BACKUP_FILE="$1"
cd "$(dirname "$0")/.."
set -a; source .env; set +a

echo "[restore] WARNING: this will overwrite the current ${POSTGRES_DB} database."
read -p "Type 'yes' to continue: " CONFIRM
[ "$CONFIRM" = "yes" ] || { echo "Aborted."; exit 1; }

echo "[restore] Restoring from ${BACKUP_FILE}"
gunzip -c "$BACKUP_FILE" | docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB"

echo "[restore] Done."
