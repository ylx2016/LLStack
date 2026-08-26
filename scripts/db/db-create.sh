#!/bin/bash
set -euo pipefail

# Create a database with user and grant privileges
# Usage: db-create.sh --engine <mariadb|mysql|postgresql> --name <db_name> --db-user <user> --password-file <path>

ENGINE=""
DB_NAME=""
DB_USER=""
PW_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine)        ENGINE="$2"; shift 2 ;;
        --name)          DB_NAME="$2"; shift 2 ;;
        --db-user)       DB_USER="$2"; shift 2 ;;
        --password-file) PW_FILE="$2"; shift 2 ;;
        *) echo '{"ok": false, "error": "unknown_arg"}' >&2; exit 1 ;;
    esac
done

if [[ -z "$ENGINE" || -z "$DB_NAME" ]]; then
    echo '{"ok": false, "error": "missing_args", "message": "--engine and --name required"}' >&2
    exit 1
fi

# Validate database name (alphanumeric + underscore)
if ! echo "$DB_NAME" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,63}$'; then
    echo '{"ok": false, "error": "invalid_db_name"}' >&2
    exit 1
fi

# Read password from file
DB_PASS=""
if [[ -n "$PW_FILE" && -f "$PW_FILE" ]]; then
    DB_PASS=$(cat "$PW_FILE")
    rm -f "$PW_FILE"
fi

case "$ENGINE" in
    mariadb|mysql)
        # Validate DB user format
        if [[ -n "$DB_USER" ]] && ! echo "$DB_USER" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,31}$'; then
            echo '{"ok": false, "error": "invalid_db_user"}' >&2; exit 1
        fi

        # Create database
        if ! mysql -e "CREATE DATABASE IF NOT EXISTS \`$DB_NAME\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;"; then
            echo '{"ok": false, "error": "create_database_failed"}' >&2; exit 1
        fi

        # Create user and grant — feed SQL via stdin (temp file) so the password
        # never appears in argv (ps leak); printf does not shell-interpret the value.
        if [[ -n "$DB_USER" && -n "$DB_PASS" ]]; then
            # MariaDB: use mysql_native_password (10.11+ defaults to unix_socket)
            # MySQL/Percona: use mysql_native_password (8.0+ defaults to caching_sha2_password)
            ESCAPED_PASS="${DB_PASS//\\/\\\\}"
            ESCAPED_PASS="${ESCAPED_PASS//\'/\'\'}"
            SQL_TMP=$(mktemp); mv "$SQL_TMP" "${SQL_TMP}.sql"; SQL_TMP="${SQL_TMP}.sql"
            # GNU mktemp template must end in X; rename after creation.
            trap 'rm -f -- "$SQL_TMP"' EXIT
            printf '%s\n' \
"CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('$ESCAPED_PASS');" > "$SQL_TMP"
            if ! mysql < "$SQL_TMP" 2>/dev/null; then
                printf '%s\n' \
"CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED WITH mysql_native_password BY '$ESCAPED_PASS';" > "$SQL_TMP"
                if ! mysql < "$SQL_TMP" 2>/dev/null; then
                    printf '%s\n' \
"CREATE USER IF NOT EXISTS '$DB_USER'@'localhost' IDENTIFIED BY '$ESCAPED_PASS';" > "$SQL_TMP"
                    if ! mysql < "$SQL_TMP"; then
                        echo '{"ok": false, "error": "create_user_failed"}' >&2; exit 1
                    fi
                fi
            fi
            printf '%s\n' \
"GRANT ALL PRIVILEGES ON \`$DB_NAME\`.* TO '$DB_USER'@'localhost';" > "$SQL_TMP"
            if ! mysql < "$SQL_TMP"; then
                echo '{"ok": false, "error": "grant_failed"}' >&2; exit 1
            fi
            printf 'FLUSH PRIVILEGES;\n' > "$SQL_TMP"
            if ! mysql < "$SQL_TMP"; then
                echo '{"ok": false, "error": "flush_privileges_failed"}' >&2; exit 1
            fi
        fi

        HOST="localhost"
        PORT=3306
        ;;

    postgresql)
        # Validate user (double-quoted identifier — must be a plain identifier)
        if [[ -n "$DB_USER" ]] && ! echo "$DB_USER" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,31}$'; then
            echo '{"ok": false, "error": "invalid_db_user"}' >&2; exit 1
        fi
        # Create user (escape single quotes in password)
        if [[ -n "$DB_USER" && -n "$DB_PASS" ]]; then
            ESCAPED_PASS="${DB_PASS//\'/\'\'}"
            if ! sudo -u postgres psql -c "CREATE USER \"$DB_USER\" WITH PASSWORD '${ESCAPED_PASS}';"; then
                echo '{"ok": false, "error": "create_user_failed"}' >&2; exit 1
            fi
        fi

        # Create database
        if ! sudo -u postgres psql -c "CREATE DATABASE \"$DB_NAME\" OWNER \"${DB_USER:-postgres}\";"; then
            echo '{"ok": false, "error": "create_database_failed"}' >&2; exit 1
        fi

        HOST="localhost"
        PORT=5432
        ;;

    *)
        echo '{"ok": false, "error": "unsupported_engine"}' >&2
        exit 1
        ;;
esac

# Use Python for JSON serialization so user-supplied values containing " or \
# cannot break the contract the backend parses the whole of stdout for.
python3 - "$DB_NAME" "$ENGINE" "$DB_USER" "$HOST" "$PORT" <<'PYEOF'
import json, sys
name, engine, user, host, port = sys.argv[1:6]
print(json.dumps({
    "ok": True,
    "data": {"name": name, "engine": engine, "user": user, "host": host, "port": int(port)},
}, separators=(",", ":")))
PYEOF
