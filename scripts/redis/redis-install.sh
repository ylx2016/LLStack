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
systemctl enable --now redis 2>/dev/null || systemctl enable --now valkey 2>/dev/null || true

echo ">>> Redis installed" >&2
redis-server --version 2>/dev/null || valkey-server --version 2>/dev/null || true
echo '{"ok":true}'
