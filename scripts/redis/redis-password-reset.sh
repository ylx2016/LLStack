#!/bin/bash
set -euo pipefail
USER="" PASSWORD="${REDIS_PASSWORD:-}"
while [[ $# -gt 0 ]]; do case "$1" in --user) USER="$2"; shift 2 ;; --password) PASSWORD="$2"; shift 2 ;; *) shift ;; esac; done
[[ -z "$USER" || -z "$PASSWORD" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }
# Validate the user exists and is a plain username (prevent path traversal)
if ! id "$USER" &>/dev/null || ! [[ "$USER" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo '{"ok":false,"error":"invalid_user"}' >&2; exit 1
fi
# Reject passwords with control characters (incl. newline, which grep is line-oriented and
# would miss) to prevent redis.conf injection
if [[ "$PASSWORD" =~ $'\n' ]] || printf '%s' "$PASSWORD" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    echo '{"ok":false,"error":"invalid_password_chars"}' >&2; exit 1
fi
HOME_DIR=$(getent passwd "$USER" | cut -d: -f6)
[[ -z "$HOME_DIR" ]] && HOME_DIR="/home/$USER"
CONF="$HOME_DIR/.redis/redis.conf"
[[ ! -f "$CONF" ]] && { echo '{"ok":false,"error":"conf_not_found"}' >&2; exit 1; }
# Escape special chars for sed replacement
ESCAPED_PW=$(printf '%s\n' "$PASSWORD" | sed -e 's/[|&/\\]/\\&/g')
sed -i "s|^requirepass .*|requirepass $ESCAPED_PW|" "$CONF"
systemctl restart "redis@$USER" 2>/dev/null || true
echo '{"ok":true}'
