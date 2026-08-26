#!/bin/bash
set -euo pipefail
USER=""
while [[ $# -gt 0 ]]; do case "$1" in --user) USER="$2"; shift 2 ;; *) shift ;; esac; done
[[ -z "$USER" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }
# Validate the user exists and is a plain username (prevent path traversal in rm -rf)
if ! id "$USER" &>/dev/null || ! [[ "$USER" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo '{"ok":false,"error":"invalid_user"}' >&2; exit 1
fi
HOME_DIR=$(getent passwd "$USER" | cut -d: -f6)
if [[ -z "$HOME_DIR" ]]; then
    echo '{"ok":false,"error":"home_not_found"}' >&2; exit 1
fi
systemctl stop "redis@$USER" 2>/dev/null || true
systemctl disable "redis@$USER" 2>/dev/null || true
rm -rf "$HOME_DIR/.redis"
echo "{\"ok\":true,\"data\":{\"user\":\"$USER\"}}"
