#!/bin/bash
set -euo pipefail

# Import/restore a database from SQL dump
# Usage: db-import.sh --engine <mariadb|mysql|postgresql> --name <db_name> --file <path>

ENGINE="" NAME="" FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine) ENGINE="$2"; shift 2 ;;
        --name)   NAME="$2"; shift 2 ;;
        --file)   FILE="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$ENGINE" || -z "$NAME" || -z "$FILE" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }
[[ ! -f "$FILE" ]] && { echo '{"ok":false,"error":"file_not_found"}' >&2; exit 1; }

case "$ENGINE" in
    mariadb|mysql|postgresql) ;;
    *) echo '{"ok":false,"error":"unsupported_engine"}' >&2; exit 1 ;;
esac

# DB name must be a plain identifier so it can't be used for SQL injection.
if ! echo "$NAME" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,63}$'; then
    echo '{"ok":false,"error":"invalid_db_name"}' >&2; exit 1
fi

case "$ENGINE" in
    mariadb|mysql)
        # set -o pipefail is implicit; a failing mysql after a successful
        # gunzip is reported as a script failure.
        if [[ "$FILE" == *.gz ]]; then
            if ! gunzip -c "$FILE" | mysql "$NAME"; then
                echo '{"ok":false,"error":"import_failed","message":"Database import failed"}' >&2; exit 1
            fi
        else
            if ! mysql "$NAME" < "$FILE"; then
                echo '{"ok":false,"error":"import_failed","message":"Database import failed"}' >&2; exit 1
            fi
        fi
        ;;
    postgresql)
        if [[ "$FILE" == *.gz ]]; then
            if ! gunzip -c "$FILE" | sudo -u postgres psql "$NAME" -v ON_ERROR_STOP=1; then
                echo '{"ok":false,"error":"import_failed","message":"Database import failed"}' >&2; exit 1
            fi
        else
            if ! sudo -u postgres psql "$NAME" -v ON_ERROR_STOP=1 < "$FILE"; then
                echo '{"ok":false,"error":"import_failed","message":"Database import failed"}' >&2; exit 1
            fi
        fi
        ;;
esac

# Note: caller handles file cleanup
python3 - "$NAME" "$ENGINE" <<'PYEOF'
import json, sys
name, engine = sys.argv[1], sys.argv[2]
print(json.dumps({"ok": True, "data": {"database": name, "engine": engine}}, separators=(",", ":")))
PYEOF
