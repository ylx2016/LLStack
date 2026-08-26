#!/bin/bash
set -euo pipefail

# Create a database user with privileges
# Usage: db-user-create.sh --engine <mariadb|mysql|postgresql> --db-name <name> --db-user <user> --host <host> --password-file <path>

ENGINE="" DB_NAME="" DB_USER="" HOST="localhost" PW_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine)        ENGINE="$2"; shift 2 ;;
        --db-name)       DB_NAME="$2"; shift 2 ;;
        --db-user)       DB_USER="$2"; shift 2 ;;
        --host)          HOST="$2"; shift 2 ;;
        --password-file) PW_FILE="$2"; shift 2 ;;
        *) echo '{"ok": false, "error": "unknown_arg"}' >&2; exit 1 ;;
    esac
done

if [[ -z "$ENGINE" || -z "$DB_NAME" || -z "$DB_USER" || -z "$PW_FILE" ]]; then
    echo '{"ok": false, "error": "missing_args"}' >&2; exit 1
fi
if [[ ! -f "$PW_FILE" ]]; then
    echo '{"ok": false, "error": "password_file_not_found"}' >&2; exit 1
fi

case "$ENGINE" in
    mariadb|mysql|postgresql) ;;
    *) echo '{"ok": false, "error": "unsupported_engine"}' >&2; exit 1 ;;
esac

# Validate inputs
if ! echo "$DB_USER" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,31}$'; then
    echo '{"ok": false, "error": "invalid_username"}' >&2; exit 1
fi
if ! echo "$DB_NAME" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,63}$'; then
    echo '{"ok": false, "error": "invalid_db_name"}' >&2; exit 1
fi
if ! echo "$HOST" | grep -qP '^[a-zA-Z0-9._%-]+$'; then
    echo '{"ok": false, "error": "invalid_host"}' >&2; exit 1
fi

DB_PASS=$(cat "$PW_FILE")
rm -f "$PW_FILE"

# Reject passwords with control characters early — they would also break
# the SQL escaping below, but surfacing the error here is clearer.
if [[ "$DB_PASS" =~ $'\n' ]] || printf '%s' "$DB_PASS" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    echo '{"ok": false, "error": "invalid_password_chars"}' >&2; exit 1
fi

case "$ENGINE" in
    mariadb|mysql)
        # Escape backslashes first, then single quotes (prevents \' bypass)
        ESCAPED_PASS="${DB_PASS//\\/\\\\}"
        ESCAPED_PASS="${ESCAPED_PASS//\'/\'\'}"
        # GNU mktemp template must end in X; rename after creation.
        SQL_TMP=$(mktemp); mv "$SQL_TMP" "${SQL_TMP}.sql"; SQL_TMP="${SQL_TMP}.sql"
        trap 'rm -f -- "$SQL_TMP"' EXIT
        printf '%s\n' \
"CREATE USER IF NOT EXISTS '${DB_USER}'@'${HOST}' IDENTIFIED VIA mysql_native_password USING PASSWORD('${ESCAPED_PASS}');" > "$SQL_TMP"
        if ! mysql < "$SQL_TMP" 2>/dev/null; then
            printf '%s\n' \
"CREATE USER IF NOT EXISTS '${DB_USER}'@'${HOST}' IDENTIFIED WITH mysql_native_password BY '${ESCAPED_PASS}';" > "$SQL_TMP"
            if ! mysql < "$SQL_TMP" 2>/dev/null; then
                printf '%s\n' \
"CREATE USER IF NOT EXISTS '${DB_USER}'@'${HOST}' IDENTIFIED BY '${ESCAPED_PASS}';" > "$SQL_TMP"
                if ! mysql < "$SQL_TMP"; then
                    echo '{"ok": false, "error": "create_user_failed"}' >&2; exit 1
                fi
            fi
        fi
        printf '%s\n' \
"GRANT ALL PRIVILEGES ON \`${DB_NAME}\`.* TO '${DB_USER}'@'${HOST}';" > "$SQL_TMP"
        if ! mysql < "$SQL_TMP"; then
            echo '{"ok": false, "error": "grant_failed"}' >&2; exit 1
        fi
        printf 'FLUSH PRIVILEGES;\n' > "$SQL_TMP"
        if ! mysql < "$SQL_TMP"; then
            echo '{"ok": false, "error": "flush_privileges_failed"}' >&2; exit 1
        fi
        ;;
    postgresql)
        # Escape single quotes and backslashes for PostgreSQL
        ESCAPED_PASS="${DB_PASS//\\/\\\\}"
        ESCAPED_PASS="${ESCAPED_PASS//\'/\'\'}"
        if ! sudo -u postgres psql -c "CREATE USER \"${DB_USER}\" WITH PASSWORD '${ESCAPED_PASS}';"; then
            echo '{"ok": false, "error": "create_user_failed"}' >&2; exit 1
        fi
        if ! sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE \"${DB_NAME}\" TO \"${DB_USER}\";"; then
            echo '{"ok": false, "error": "grant_failed"}' >&2; exit 1
        fi
        ;;
esac

# Use Python for JSON serialization. Include the user/host/port so the panel
# can render a usable "manage DB" view.
python3 - "$ENGINE" "$DB_NAME" "$DB_USER" "$HOST" <<'PYEOF'
import json, sys
engine, db_name, db_user, host = sys.argv[1:5]
print(json.dumps({
    "ok": True,
    "data": {"engine": engine, "database": db_name, "user": db_user, "host": host},
}, separators=(",", ":")))
PYEOF
