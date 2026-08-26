#!/bin/bash
set -euo pipefail

# Get status of a user's Redis instance
# Usage: REDIS_PASSWORD=xxx redis-instance-status.sh --user <system_user>

USER=""
PASSWORD="${REDIS_PASSWORD:-}"
PW_FILE=""
REDIS_CLI_BIN=$(command -v redis-cli 2>/dev/null || command -v valkey-cli 2>/dev/null || echo "redis-cli")

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)          USER="$2"; shift 2 ;;
        --password)      PASSWORD="$2"; shift 2 ;;  # legacy fallback (visible in ps)
        --password-file) PW_FILE="$2"; shift 2 ;;
        *) echo '{"ok": false, "error": "unknown_arg"}' >&2; exit 1 ;;
    esac
done

# Prefer a password file: no ps leak, and no `sudo VAR=x` env prefix needed.
if [[ -n "$PW_FILE" && -f "$PW_FILE" ]]; then
    PASSWORD=$(cat "$PW_FILE")
    rm -f -- "$PW_FILE"
fi

if [[ -z "$USER" ]]; then
    echo '{"ok": false, "error": "missing_args"}' >&2
    exit 1
fi

# Validate the user exists and is a plain username, and resolve the real home dir
# (the systemd unit uses %h, so this must match the user's actual home).
if ! id "$USER" &>/dev/null || ! [[ "$USER" =~ ^[a-zA-Z0-9_.-]+$ ]]; then
    echo '{"ok": false, "error": "invalid_user"}' >&2
    exit 1
fi
if [[ "$USER" == "root" ]]; then
    HOME_DIR="/var/lib/llstack"
else
    HOME_DIR=$(getent passwd "$USER" | cut -d: -f6)
fi
SOCKET="$HOME_DIR/.redis/redis.sock"
SERVICE="redis@$USER"

# Check if running
if ! systemctl is-active "$SERVICE" &>/dev/null; then
    echo '{"ok": true, "data": {"status": "stopped", "memory_used_bytes": 0, "memory_peak_bytes": 0, "connected_clients": 0, "hit_rate": 0, "uptime_seconds": 0}}'
    exit 0
fi

# Get INFO from Redis (password via REDISCLI_AUTH env to avoid /proc exposure)
export REDISCLI_AUTH="${PASSWORD}"

INFO=$($REDIS_CLI_BIN -s "$SOCKET" --no-auth-warning INFO 2>/dev/null || echo "")

if [[ -z "$INFO" ]]; then
    echo '{"ok": true, "data": {"status": "running", "memory_used_bytes": 0, "memory_peak_bytes": 0, "connected_clients": 0, "hit_rate": 0, "uptime_seconds": 0}}'
    exit 0
fi

MEM_USED=$(echo "$INFO" | grep "^used_memory:" | cut -d: -f2 | tr -d '\r' || echo "0")
MEM_PEAK=$(echo "$INFO" | grep "^used_memory_peak:" | cut -d: -f2 | tr -d '\r' || echo "0")
CLIENTS=$(echo "$INFO" | grep "^connected_clients:" | cut -d: -f2 | tr -d '\r' || echo "0")
UPTIME=$(echo "$INFO" | grep "^uptime_in_seconds:" | cut -d: -f2 | tr -d '\r' || echo "0")

HITS=$(echo "$INFO" | grep "^keyspace_hits:" | cut -d: -f2 | tr -d '\r' || echo "0")
MISSES=$(echo "$INFO" | grep "^keyspace_misses:" | cut -d: -f2 | tr -d '\r' || echo "0")
TOTAL=$((HITS + MISSES))
if [[ "$TOTAL" -gt 0 ]]; then
    HIT_RATE=$(awk "BEGIN{printf \"%.1f\", $HITS * 100.0 / $TOTAL}")
else
    HIT_RATE="0.0"
fi

# Use Python for JSON serialization. All values are system-derived but the
# contract still calls for a single parseable document on stdout.
python3 - "$MEM_USED" "$MEM_PEAK" "$CLIENTS" "$HIT_RATE" "$UPTIME" <<'PYEOF'
import json, sys
mu, mp, cc, hr, ut = (
    int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), float(sys.argv[4]), int(sys.argv[5])
)
print(json.dumps({
    "ok": True,
    "data": {
        "status": "running",
        "memory_used_bytes": mu,
        "memory_peak_bytes": mp,
        "connected_clients": cc,
        "hit_rate": hr,
        "uptime_seconds": ut,
    },
}, separators=(",", ":")))
PYEOF
