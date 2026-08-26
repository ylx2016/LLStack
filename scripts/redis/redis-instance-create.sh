#!/bin/bash
set -euo pipefail

# Create a per-user Redis instance with Unix socket isolation
# Usage: REDIS_PASSWORD=xxx redis-instance-create.sh --user <system_user> --maxmemory <MB>

USER=""
MAXMEMORY=64
PASSWORD="${REDIS_PASSWORD:-}"
PW_FILE=""

# Detect redis-server/redis-cli or valkey equivalents
REDIS_SERVER_BIN=$(command -v redis-server 2>/dev/null || command -v valkey-server 2>/dev/null || echo "/usr/bin/redis-server")
REDIS_CLI_BIN=$(command -v redis-cli 2>/dev/null || command -v valkey-cli 2>/dev/null || echo "/usr/bin/redis-cli")

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)          USER="$2"; shift 2 ;;
        --maxmemory)     MAXMEMORY="$2"; shift 2 ;;
        --password)      PASSWORD="$2"; shift 2 ;;  # legacy fallback (visible in ps)
        --password-file) PW_FILE="$2"; shift 2 ;;
        *) echo '{"ok": false, "error": "unknown_arg"}' >&2; exit 1 ;;
    esac
done

# Prefer a password file: no ps leak, and no `sudo VAR=x` env prefix (which sudo
# refuses without a SETENV tag) is needed to reach this script.
if [[ -n "$PW_FILE" && -f "$PW_FILE" ]]; then
    PASSWORD=$(cat "$PW_FILE")
    rm -f -- "$PW_FILE"
fi

if [[ -z "$USER" || -z "$PASSWORD" ]]; then
    echo '{"ok": false, "error": "missing_args", "message": "--user and REDIS_PASSWORD env required"}' >&2
    exit 1
fi

# Reject passwords with control characters (prevent redis.conf injection)
# \t (0x09) is included by [[:cntrl:]] in LC_ALL=C and rejected; backslash (0x5c)
# is NOT, so a password like "foo\nbar" (4 chars f,o,o,\,n,b,a,r) would slip
# through and break the requirepass line on the next sed pass. Reject it too.
if [[ "$PASSWORD" =~ $'\n\t' ]] || printf '%s' "$PASSWORD" | LC_ALL=C grep -qE '[[:cntrl:]]|\\'; then
    echo '{"ok": false, "error": "invalid_password_chars"}' >&2; exit 1
fi

# Validate maxmemory: positive integer AND within a sane ceiling so a typo
# (`--maxmemory 999999999999`) doesn't make Redis demand 1TB of RAM and OOM-kill
# the box on startup. 64GB covers the largest planned deployments.
if ! [[ "$MAXMEMORY" =~ ^[0-9]+$ ]] || [[ "$MAXMEMORY" -lt 1 || "$MAXMEMORY" -gt 65536 ]]; then
    echo '{"ok": false, "error": "invalid_maxmemory", "message": "--maxmemory must be 1..65536 (MB)"}' >&2; exit 1
fi

if ! id "$USER" &>/dev/null; then
    echo '{"ok": false, "error": "user_not_found"}' >&2
    exit 1
fi

# Avoid /root/ for redis data (nobody can't access)
if [[ "$USER" == "root" ]]; then
    HOME_DIR="/var/lib/llstack"
else
    HOME_DIR=$(getent passwd "$USER" | cut -d: -f6)
fi
REDIS_DIR="$HOME_DIR/.redis"
REDIS_CONF="$REDIS_DIR/redis.conf"
REDIS_SOCK="$REDIS_DIR/redis.sock"
SERVICE_NAME="redis@$USER"

# Check if already exists
if systemctl is-active "$SERVICE_NAME" &>/dev/null; then
    echo '{"ok": false, "error": "already_exists"}' >&2
    exit 1
fi

# 1. Create Redis directory
mkdir -p "$REDIS_DIR"
chown "$USER:$USER" "$REDIS_DIR"
chmod 700 "$REDIS_DIR"

# 2. Generate redis.conf (escape password for config file).
# Escape every char that redis.conf cares about: backslash, double quote, and
# every non-printable byte. The previous version only escaped \" and \\, which
# meant a password containing anything else (e.g. \n in the two-byte form
# \ + n, or other shell-special chars) would silently break auth at runtime.
ESCAPED_PW=$(printf '%s' "$PASSWORD" | python3 -c '
import sys
s = sys.stdin.read()
# redis.conf string tokens: backslash-escape the few characters redis treats
# specially. The result is wrapped in double quotes below.
print(s.replace("\\", "\\\\").replace("\"", "\\\""), end="")
')

cat > "$REDIS_CONF" << CONFEOF
# LLStack managed Redis instance for $USER
# Do not edit manually - managed by llstack panel

# Bind to Unix socket only (no TCP)
port 0
unixsocket $REDIS_SOCK
unixsocketperm 700

# Authentication
requirepass "$ESCAPED_PW"

# Memory
maxmemory ${MAXMEMORY}mb
maxmemory-policy allkeys-lru

# Persistence (minimal - AOF for crash recovery)
appendonly yes
appendfilename "appendonly.aof"
appendfsync everysec
dir $REDIS_DIR

# Logging
logfile $REDIS_DIR/redis.log
loglevel notice

# Performance
save ""
tcp-backlog 128
timeout 300
databases 16

# Slow log
slowlog-log-slower-than 10000
slowlog-max-len 128

# Security
rename-command FLUSHALL ""
rename-command CONFIG ""
rename-command DEBUG ""
CONFEOF

chown "$USER:$USER" "$REDIS_CONF"
chmod 600 "$REDIS_CONF"

# 3. Create systemd unit with the concrete paths for THIS user.
# A per-user unit (not a shared template) avoids two bugs: (a) the root instance's
# home is /var/lib/llstack while the template's %h would resolve to /root; (b) a
# shared template gets overwritten when different users use different redis/valkey
# binaries. The env/conf/socket live in REDIS_DIR, so embed it directly.
UNIT_FILE="/etc/systemd/system/redis@${USER}.service"
cat > "$UNIT_FILE" <<SVCEOF
[Unit]
Description=Redis/Valkey instance for ${USER}
After=network.target

[Service]
Type=simple
User=${USER}
Group=${USER}
EnvironmentFile=-${REDIS_DIR}/env
ExecStart=${REDIS_SERVER_BIN} ${REDIS_DIR}/redis.conf
# Pass the password via the EnvironmentFile. Earlier versions interpolated
# REDIS_PASSWORD into a bash -c "..." string, which double-expanded $ and
# broke passwords containing $, ", or \ — shutdown then hung.
ExecStop=${REDIS_CLI_BIN} -s ${REDIS_DIR}/redis.sock -a \$\{REDIS_PASSWORD\} shutdown nosave
Restart=always
RestartSec=5
LimitNOFILE=10032
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
SVCEOF
systemctl daemon-reload

# 3b. Create env file for systemd (password not visible in unit or /proc).
# systemd's EnvironmentFile format treats lines starting with # as comments
# and $ as variable references, so a password containing either would silently
# be truncated or empty. Quoting the value preserves it.
ENV_FILE="$REDIS_DIR/env"
printf 'REDIS_PASSWORD="%s"\n' "$PASSWORD" > "$ENV_FILE"
chown "$USER:$USER" "$ENV_FILE"
chmod 600 "$ENV_FILE"

# 4. Enable and start
# Tolerate enable failing (e.g. template unit already present) so start always runs.
systemctl enable "$SERVICE_NAME" 2>/dev/null || true
systemctl start "$SERVICE_NAME"

# 5. Wait for socket
for i in {1..10}; do
    if [[ -S "$REDIS_SOCK" ]]; then
        break
    fi
    sleep 0.5
done

# 6. Verify
if systemctl is-active "$SERVICE_NAME" &>/dev/null; then
    STATUS="running"
else
    STATUS="failed"
fi

# Use Python for JSON serialization. $USER is validated to a username
# regex and $REDIS_SOCK/$STATUS are system-controlled, but json.dumps
# is still the right tool — the JSON contract says "one parseable doc",
# and this guarantees it.
python3 - "$USER" "$REDIS_SOCK" "$MAXMEMORY" "$STATUS" <<'PYEOF'
import json, sys
user, sock, maxmem, status = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]
print(json.dumps({
    "ok": True,
    "data": {
        "user": user,
        "socket_path": sock,
        "maxmemory_mb": maxmem,
        "status": status,
    },
}, separators=(",", ":")))
PYEOF
