#!/bin/bash
set -euo pipefail
# Install Redis server
# EL9: redis from AppStream (7.x)
# EL10: redis or valkey from default repos

MAJOR_VER=$(. /etc/os-release; echo "${VERSION_ID%%.*}")

echo ">>> Installing Redis..." >&2
if [[ "$MAJOR_VER" == "10" ]]; then
    # EL10 ships Redis 7.x or Valkey as replacement
    dnf install -y redis 2>&1 || dnf install -y valkey 2>&1
else
    dnf install -y redis >&2 2>&1
fi

echo ">>> Starting Redis..." >&2
# Start whichever unit the system actually has. EL10 drops the redis
# package in favor of valkey, so systemctl enable --now redis would fail.
# The fallback chain below lets either work, and we then create a
# `redis.service` symlink so any caller (the panel backend in particular)
# checking for the historical name still gets a positive answer.
if systemctl enable --now valkey &>/dev/null; then
    BACKEND="valkey"
elif systemctl enable --now redis &>/dev/null; then
    BACKEND="redis"
else
    echo '{"ok":false,"error":"start_failed","message":"neither valkey nor redis service could be started"}' >&2
    exit 1
fi

# Many tools (including the panel's own backend) hardcode `redis.service`
# as the unit name. Make that work for valkey too.
if [[ "$BACKEND" == "valkey" && ! -e /etc/systemd/system/redis.service ]]; then
    ln -s valkey.service /etc/systemd/system/redis.service
    systemctl daemon-reload
    echo "    (added /etc/systemd/system/redis.service → valkey.service so legacy 'redis' checks work)" >&2
fi

echo ">>> Redis installed" >&2
redis-server --version 2>/dev/null || valkey-server --version 2>/dev/null || true
echo "{\"ok\":true,\"data\":{\"backend\":\"$BACKEND\"}}"
