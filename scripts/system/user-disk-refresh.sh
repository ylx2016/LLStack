#!/bin/bash
# Refresh per-user home directory disk usage cache.
#
# Reads users.home_dir from the panel DB, runs `du -sm` for each, and
# upserts results into user_disk_usage. Designed for cron — runs offline
# from any HTTP request so a slow `du` cannot tie up a gunicorn worker.
set -euo pipefail

DB_PATH="${LLSTACK_DB_PATH:-/opt/llstack/data/llstack.db}"

if [[ ! -f "$DB_PATH" ]]; then
    echo '{"ok":false,"error":"db_not_found"}' >&2
    exit 1
fi

# Collect (id, home_dir) pairs. Skip rows with empty home_dir.
mapfile -t rows < <(sqlite3 "$DB_PATH" \
    "SELECT id || '|' || COALESCE(home_dir, '') FROM users WHERE home_dir IS NOT NULL AND home_dir != ''")

updated=0
for row in "${rows[@]}"; do
    uid="${row%%|*}"
    home="${row#*|}"
    [[ -d "$home" ]] || continue
    # 60s ceiling per user to keep the whole job bounded.
    mb=$(timeout 60 du -sm "$home" 2>/dev/null | awk '{print $1}' || echo 0)
    [[ "$mb" =~ ^[0-9]+$ ]] || mb=0
    sqlite3 "$DB_PATH" \
        "INSERT INTO user_disk_usage (user_id, mb, updated_at) VALUES ($uid, $mb, CURRENT_TIMESTAMP)
         ON CONFLICT(user_id) DO UPDATE SET mb = excluded.mb, updated_at = CURRENT_TIMESTAMP;"
    updated=$((updated + 1))
done

echo "{\"ok\":true,\"updated\":$updated}"
