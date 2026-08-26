#!/bin/bash
set -euo pipefail
VERSION="" KEY="" VALUE=""
while [[ $# -gt 0 ]]; do case "$1" in --version) VERSION="$2"; shift 2 ;; --key) KEY="$2"; shift 2 ;; --value) VALUE="$2"; shift 2 ;; *) shift ;; esac; done
[[ -z "$VERSION" || -z "$KEY" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }
# Defense in depth: validate VERSION and KEY formats even though the API layer whitelists them
[[ "$VERSION" =~ ^[0-9]+$ ]] || { echo '{"ok":false,"error":"invalid_version"}' >&2; exit 1; }
[[ "$KEY" =~ ^[a-zA-Z_][a-zA-Z0-9_.]*$ ]] || { echo '{"ok":false,"error":"invalid_key"}' >&2; exit 1; }
INI="/etc/opt/remi/php${VERSION}/php.ini"
[[ ! -f "$INI" ]] && { echo '{"ok":false,"error":"ini_not_found"}' >&2; exit 1; }
# Reject control characters in VALUE (incl. newline, which grep is line-oriented and would
# miss) to prevent injection of extra directives into php.ini.
if [[ "$VALUE" =~ $'\n' ]] || printf '%s' "$VALUE" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    echo '{"ok":false,"error":"invalid_value"}' >&2; exit 1
fi
# Escape sed replacement chars in VALUE (| is our delimiter; \ and & are sed-special)
ESC_VALUE=$(printf '%s' "$VALUE" | sed -e 's/[|\\&]/\\&/g')
if grep -q "^${KEY}\s*=" "$INI"; then
    sed -i "s|^${KEY}\s*=.*|${KEY} = ${ESC_VALUE}|" "$INI"
else
    echo "${KEY} = ${VALUE}" >> "$INI"
fi
# JSON-escape VALUE for safe stdout
JSON_VALUE=$(printf '%s' "$VALUE" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')
echo "{\"ok\":true,\"data\":{\"key\":\"$KEY\",\"value\":$JSON_VALUE}}"
