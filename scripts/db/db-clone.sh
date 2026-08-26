#!/bin/bash
set -euo pipefail

# Clone a database
# Usage: db-clone.sh --engine <engine> --source <db_name> --target <db_name>

ENGINE="" SOURCE="" TARGET=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine) ENGINE="$2"; shift 2 ;;
        --source) SOURCE="$2"; shift 2 ;;
        --target) TARGET="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$ENGINE" || -z "$SOURCE" || -z "$TARGET" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }

for name in "$SOURCE" "$TARGET"; do
    if ! echo "$name" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,63}$'; then
        echo '{"ok":false,"error":"invalid_db_name"}' >&2; exit 1
    fi
done

[[ "$SOURCE" == "$TARGET" ]] && { echo '{"ok":false,"error":"source_equals_target"}' >&2; exit 1; }

case "$ENGINE" in
    mariadb|mysql)
        # Verify source exists BEFORE creating the target. Otherwise
        # `mysqldump <missing>` errors silently (we'll catch it), but
        # CREATE DATABASE IF NOT EXISTS has already created the target
        # and the script reports "success" with an empty database.
        if ! mysql -N -B -e "SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = '$SOURCE';" 2>/dev/null | grep -qx "$SOURCE"; then
            echo '{"ok":false,"error":"source_db_not_found","message":"'"$SOURCE"' does not exist"}' >&2
            exit 1
        fi
        if ! mysql -e "CREATE DATABASE IF NOT EXISTS \`$TARGET\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null; then
            echo '{"ok":false,"error":"create_target_failed"}' >&2
            exit 1
        fi
        # No `2>/dev/null` on mysqldump: a dump that fails mid-stream
        # would leave the target half-imported and the script would still
        # report success.
        if ! mysqldump --single-transaction --quick --routines --triggers --events "$SOURCE" | mysql "$TARGET"; then
            echo '{"ok":false,"error":"clone_failed","message":"mysqldump | mysql failed; check stderr for details"}' >&2
            exit 1
        fi
        ;;
    postgresql)
        # Terminate active connections to source DB (required for TEMPLATE)
        # SOURCE is pre-validated: ^[a-zA-Z][a-zA-Z0-9_]{0,63}$ — safe for SQL string literal
        if ! sudo -u postgres psql -tAc "SELECT 1 FROM pg_database WHERE datname = '$SOURCE';" 2>/dev/null | grep -q 1; then
            echo '{"ok":false,"error":"source_db_not_found","message":"'"$SOURCE"' does not exist"}' >&2
            exit 1
        fi
        sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$SOURCE' AND pid <> pg_backend_pid();" 2>/dev/null || true
        if ! sudo -u postgres psql -c "CREATE DATABASE \"$TARGET\" TEMPLATE \"$SOURCE\";" 2>/dev/null; then
            # Fallback: dump + restore if TEMPLATE fails. Surface errors rather
            # than swallowing them with `2>/dev/null` on every command.
            if ! sudo -u postgres psql -c "CREATE DATABASE \"$TARGET\";"; then
                echo '{"ok":false,"error":"create_target_failed"}' >&2
                exit 1
            fi
            if ! sudo -u postgres pg_dump "$SOURCE" | sudo -u postgres psql "$TARGET" 2>/dev/null; then
                echo '{"ok":false,"error":"clone_failed","message":"pg_dump | psql failed"}' >&2
                exit 1
            fi
        fi
        ;;
    *) echo '{"ok":false,"error":"unsupported_engine"}' >&2; exit 1 ;;
esac

# Use Python for JSON serialization so user-supplied values containing " or \
# cannot break the contract the backend parses the whole of stdout for.
python3 - "$SOURCE" "$TARGET" "$ENGINE" <<'PYEOF'
import json, sys
source, target, engine = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "ok": True,
    "data": {"source": source, "target": target, "engine": engine},
}, separators=(",", ":")))
PYEOF
