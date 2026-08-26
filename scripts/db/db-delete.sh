#!/bin/bash
set -euo pipefail
ENGINE="" NAME=""
while [[ $# -gt 0 ]]; do case "$1" in --engine) ENGINE="$2"; shift 2 ;; --name) NAME="$2"; shift 2 ;; *) shift ;; esac; done
[[ -z "$ENGINE" || -z "$NAME" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }
# Validate engine and name — name must be a plain identifier to prevent SQL injection
case "$ENGINE" in
    mariadb|mysql|postgresql) ;;
    *) echo '{"ok":false,"error":"unsupported_engine"}' >&2; exit 1 ;;
esac
if ! echo "$NAME" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,63}$'; then
    echo '{"ok":false,"error":"invalid_db_name"}' >&2; exit 1
fi
case "$ENGINE" in
    mariadb|mysql) mysql -e "DROP DATABASE IF EXISTS \`$NAME\`;" 2>/dev/null ;;
    postgresql) sudo -u postgres psql -c "DROP DATABASE IF EXISTS \"$NAME\";" 2>/dev/null ;;
esac
echo "{\"ok\":true,\"data\":{\"name\":\"$NAME\",\"engine\":\"$ENGINE\"}}"
