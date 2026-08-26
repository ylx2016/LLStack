#!/bin/bash
set -euo pipefail

# Start/stop/restart a user's Redis instance
# Usage: redis-instance-control.sh --user <system_user> --action <start|stop|restart>

USER=""
ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)   USER="$2"; shift 2 ;;
        --action) ACTION="$2"; shift 2 ;;
        *) echo '{"ok": false, "error": "unknown_arg"}' >&2; exit 1 ;;
    esac
done

if [[ -z "$USER" || -z "$ACTION" ]]; then
    echo '{"ok": false, "error": "missing_args"}' >&2
    exit 1
fi

# Validate the user exists and is a plain username (prevent service-name/path injection)
if ! id "$USER" &>/dev/null || ! [[ "$USER" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo '{"ok": false, "error": "invalid_user"}' >&2
    exit 1
fi

if [[ "$ACTION" != "start" && "$ACTION" != "stop" && "$ACTION" != "restart" ]]; then
    echo '{"ok": false, "error": "invalid_action"}' >&2
    exit 1
fi

SERVICE_NAME="redis@$USER"

systemctl "$ACTION" "$SERVICE_NAME" 2>/dev/null

if [[ "$ACTION" == "stop" ]]; then
    STATUS="stopped"
else
    if systemctl is-active "$SERVICE_NAME" &>/dev/null; then
        STATUS="running"
    else
        STATUS="stopped"
    fi
fi

echo "{\"ok\": true, \"data\": {\"status\": \"$STATUS\"}}"
