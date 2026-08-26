#!/bin/bash
set -euo pipefail

# Create a system user for the panel
# Usage: user-create.sh --username <name>

USERNAME=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --username) USERNAME="$2"; shift 2 ;;
        *) echo '{"ok": false, "error": "unknown_arg"}' >&2; exit 1 ;;
    esac
done

if [[ -z "$USERNAME" ]]; then
    echo '{"ok": false, "error": "missing_args", "message": "--username is required"}' >&2
    exit 1
fi

# Validate username format
if ! echo "$USERNAME" | grep -qP '^[a-z][a-z0-9_]{2,31}$'; then
    echo '{"ok": false, "error": "invalid_username", "message": "Username must be 3-32 lowercase alphanumeric chars"}' >&2
    exit 1
fi

# Check if user already exists
if id "$USERNAME" &>/dev/null; then
    echo '{"ok": false, "error": "user_exists", "message": "System user already exists"}' >&2
    exit 1
fi

HOME_DIR="/home/$USERNAME"

# 1. Create user with home directory
useradd -m -s /bin/bash -d "$HOME_DIR" "$USERNAME"

# 2. Create standard directory structure
mkdir -p "$HOME_DIR/public_html"
mkdir -p "$HOME_DIR/.redis"
mkdir -p "$HOME_DIR/logs"
mkdir -p "$HOME_DIR/tmp"

# 3. Set permissions
chown -R "$USERNAME:$USERNAME" "$HOME_DIR"
chmod 711 "$HOME_DIR"
chmod 755 "$HOME_DIR/public_html"
chmod 700 "$HOME_DIR/.redis"
chmod 750 "$HOME_DIR/logs"
chmod 700 "$HOME_DIR/tmp"

# 4. Add to lsws group (for LiteHttpd access)
# Use the actual web-server group (the 'lsws' group created by LiteHttpd) rather
# than 'nobody', which is not the intended group and grants unrelated memberships.
if getent group lsws &>/dev/null; then
    usermod -aG lsws "$USERNAME"
else
    usermod -aG nobody "$USERNAME" 2>/dev/null || true
fi

# Use Python for JSON serialization. $USERNAME is validated to a username
# regex but $HOME_DIR is system-derived and could include spaces.
python3 - "$USERNAME" "$HOME_DIR" <<'PYEOF'
import json, sys, os
username, home_dir = sys.argv[1], sys.argv[2]
try:
    uid = os.getuid() if username == "root" else __import__("pwd").getpwnam(username).pw_uid
except Exception:
    uid = 0
print(json.dumps({
    "ok": True,
    "data": {"username": username, "home_dir": home_dir, "uid": uid},
}, separators=(",", ":")))
PYEOF
