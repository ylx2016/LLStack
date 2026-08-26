#!/bin/bash
set -euo pipefail

# Delete a database
# Usage: db-delete.sh --engine <mariadb|mysql|postgresql> --name <db_name>

ENGINE="" NAME=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine) ENGINE="$2"; shift 2 ;;
        --name)   NAME="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$ENGINE" || -z "$NAME" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }

case "$ENGINE" in
    mariadb|mysql|postgresql) ;;
    *) echo '{"ok":false,"error":"unsupported_engine"}' >&2; exit 1 ;;
esac

# DB name must be a plain identifier so it can't be used for SQL injection.
if ! echo "$NAME" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,63}$'; then
    echo '{"ok":false,"error":"invalid_db_name"}' >&2; exit 1
fi

# Don't `2>/dev/null || true` here. The previous version silently swallowed
# "the DB doesn't exist", "mysql is not running", and "no permission", and
# reported ok:true with a non-existent database name as data — the panel
# then told the user the site was removed while the database was still there.
case "$ENGINE" in
    mariadb|mysql)
        if ! mysql -e "DROP DATABASE IF EXISTS \`$NAME\`;"; then
            echo '{"ok":false,"error":"drop_failed","message":"DROP DATABASE failed; check mysql is running and the name is correct"}' >&2
            exit 1
        fi
        ;;
    postgresql)
        # Terminate active connections first — DROP DATABASE on a live DB
        # errors out without this.
        sudo -u postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = '$NAME';" &>/dev/null || true
        if ! sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$NAME\";"; then
            echo '{"ok":false,"error":"drop_failed","message":"DROP DATABASE failed; check postgres is running and the name is correct"}' >&2
            exit 1
        fi
        ;;
esac

# Use Python for JSON serialization so user-supplied values containing " or \
# cannot break the contract the backend parses the whole of stdout for.
python3 - "$NAME" "$ENGINE" <<'PYEOF'
import json, sys
name, engine = sys.argv[1], sys.argv[2]
print(json.dumps({"ok": True, "data": {"name": name, "engine": engine}}, separators=(",", ":")))
PYEOF
