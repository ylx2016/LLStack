#!/bin/bash
set -euo pipefail

# Create a per-user Redis instance with Unix socket isolation
# Usage: REDIS_PASSWORD=xxx redis-instance-create.sh --user <system_user> --maxmemory <MB>

USER=""
MAXMEMORY=64
PASSWORD="${REDIS_PASSWORD:-}"

# Detect redis-server/redis-cli or valkey equivalents
REDIS_SERVER_BIN=$(command -v redis-server 2>/dev/null || command -v valkey-server 2>/dev/null || echo "/usr/bin/redis-server")
REDIS_CLI_BIN=$(command -v redis-cli 2>/dev/null || command -v valkey-cli 2>/dev/null || echo "/usr/bin/redis-cli")

while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)      USER="$2"; shift 2 ;;
        --maxmemory) MAXMEMORY="$2"; shift 2 ;;
        --password)  PASSWORD="$2"; shift 2 ;;  # legacy fallback
        *) echo '{"ok": false, "error": "unknown_arg"}' >&2; exit 1 ;;
    esac
done

if [[ -z "$USER" || -z "$PASSWORD" ]]; then
    echo '{"ok": false, "error": "missing_args", "message": "--user and REDIS_PASSWORD env required"}' >&2
    exit 1
fi

# Reject passwords with control characters (prevent redis.conf injection)
if [[ "$PASSWORD" =~ $'\n' ]] || printf '%s' "$PASSWORD" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    echo '{"ok": false, "error": "invalid_password_chars"}' >&2; exit 1
fi

# Validate maxmemory is a positive integer (prevents config injection via maxmemory line)
if ! [[ "$MAXMEMORY" =~ ^[0-9]+$ ]]; then
    echo '{"ok": false, "error": "invalid_maxmemory"}' >&2; exit 1
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

# 2. Generate redis.conf (escape password for config file)
ESCAPED_PW=$(printf '%s' "$PASSWORD" | sed -e 's/[\"\\]/\\&/g')

cat > "$REDIS_CONF" << CONFEOF
# LLStack managed Redis instance for $USER
# Do not edit manually - managed by llstack panel

# Bind to Unix socket only (no TCP)
port 0
unixsocket $REDIS_SOCK
unixsocketperm 700

# Authentication
requirepass $ESCAPED_PW

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

# 3. Create systemd template unit (if not exists)
TEMPLATE="/etc/systemd/system/redis@.service"
if [[ ! -f "$TEMPLATE" ]] || ! grep -q "$REDIS_SERVER_BIN" "$TEMPLATE" 2>/dev/null; then
    cat > "$TEMPLATE" <<SVCEOF
[Unit]
Description=Redis/Valkey instance for %i
After=network.target

[Service]
Type=simple
User=%i
Group=%i
EnvironmentFile=-%h/.redis/env
ExecStart=${REDIS_SERVER_BIN} %h/.redis/redis.conf
ExecStop=/bin/bash -c 'REDISCLI_AUTH="\$REDIS_PASSWORD" ${REDIS_CLI_BIN} -s %h/.redis/redis.sock shutdown nosave'
Restart=always
RestartSec=5
LimitNOFILE=10032
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
fi

# 3b. Create env file for systemd (password not visible in unit or /proc)
ENV_FILE="$REDIS_DIR/env"
printf 'REDIS_PASSWORD=%s\n' "$PASSWORD" > "$ENV_FILE"
chown "$USER:$USER" "$ENV_FILE"
chmod 600 "$ENV_FILE"

# 4. Enable and start
systemctl enable "$SERVICE_NAME" 2>/dev/null
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

cat << EOF
{"ok": true, "data": {"user": "$USER", "socket_path": "$REDIS_SOCK", "maxmemory_mb": $MAXMEMORY, "status": "$STATUS"}}
EOF
