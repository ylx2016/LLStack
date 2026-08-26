#!/bin/bash
set -euo pipefail

# Backup panel SQLite database (WAL-safe via sqlite3 .backup)
# Keeps last 7 daily backups

DB_PATH="${LLSTACK_DB_PATH:-/opt/llstack/data/llstack.db}"
BACKUP_DIR="/opt/llstack/backups/panel"
KEEP_DAYS=7

[[ ! -f "$DB_PATH" ]] && { echo "Panel DB not found: $DB_PATH"; exit 0; }

mkdir -p "$BACKUP_DIR"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_FILE="$BACKUP_DIR/llstack_${TIMESTAMP}.db"

# WAL-safe backup using sqlite3 .backup command
sqlite3 "$DB_PATH" ".backup '$BACKUP_FILE'" 2>/dev/null

if [[ -f "$BACKUP_FILE" ]]; then
    chmod 600 "$BACKUP_FILE"
    echo "Panel DB backed up: $BACKUP_FILE ($(stat -c%s "$BACKUP_FILE") bytes)" >&2
else
    echo "Backup failed" >&2
    exit 1
fi

# Cleanup old backups (keep last N days)
find "$BACKUP_DIR" -name "llstack_*.db" -mtime +$KEEP_DAYS -delete 2>/dev/null || true

echo '{"ok":true}'
