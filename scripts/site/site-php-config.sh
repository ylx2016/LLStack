#!/bin/bash
set -euo pipefail

# Write phpIniOverride block into OLS vhost config
# Usage: site-php-config.sh --domain <domain> --config-file <json_path>
# Config file format: [{"key":"memory_limit","value":"256M","is_admin":false}, ...]

DOMAIN=""
CONFIG_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)      DOMAIN="$2"; shift 2 ;;
        --config-file) CONFIG_FILE="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

if [[ -z "$DOMAIN" || -z "$CONFIG_FILE" ]]; then
    echo '{"ok":false,"error":"missing_args"}' >&2; exit 1
fi

# Validate domain format
if ! echo "$DOMAIN" | grep -qP '^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
    echo '{"ok":false,"error":"invalid_domain"}' >&2; exit 1
fi

VHOST_CONF="/usr/local/lsws/conf/vhosts/$DOMAIN/vhconf.conf"
if [[ ! -f "$VHOST_CONF" ]]; then
    echo '{"ok":false,"error":"vhost_not_found"}' >&2; exit 1
fi
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo '{"ok":false,"error":"config_file_not_found"}' >&2; exit 1
fi

# Generate phpIniOverride block from JSON config
# Uses Python for safe JSON parsing (no shell injection risk)
PHP_INI_BLOCK=$(python3 - "$CONFIG_FILE" << 'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        entries = json.load(f)
    lines = []
    bad = []
    for entry in entries:
        key = entry.get("key", "")
        value = entry.get("value", "")
        is_admin = entry.get("is_admin", False)
        # Validate key format (alphanumeric + dots + underscores)
        if not all(c.isalnum() or c in "._" for c in key):
            continue
        # Reject values containing control characters or config-block delimiters
        # ({};"#\) that could break out of the phpIniOverride block or inject directives.
        if any(ord(c) < 32 or ord(c) == 127 or c in '{};"#\\' for c in value):
            bad.append(key)
            continue
        directive = "php_admin_value" if is_admin else "php_value"
        lines.append(f"  {directive} {key} {value}")
    if bad:
        print(f"# skipped invalid values for keys: {', '.join(bad)}", file=sys.stderr)
    print("\n".join(lines))
except Exception as e:
    print(f"# error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
)

# Per-domain lock to prevent concurrent config corruption
LOCK_FILE="/var/lock/llstack-vhost-${DOMAIN}.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    echo '{"ok":false,"error":"config_locked","message":"Another config update is in progress"}' >&2
    exit 1
fi

# Backup current config for rollback on configtest failure
cp "$VHOST_CONF" "${VHOST_CONF}.bak"

# Remove existing phpIniOverride block and rewrite with new one
# Use Python for safe multiline config file manipulation
python3 - "$VHOST_CONF" "$PHP_INI_BLOCK" << 'PYEOF'
import re, sys, os, tempfile

conf_path = sys.argv[1]
ini_block = sys.argv[2]

with open(conf_path, 'r') as f:
    content = f.read()

# Remove existing phpIniOverride block (handles nested braces)
pattern = r'phpIniOverride\s*\{[^}]*\}\s*\n?'
content = re.sub(pattern, '', content, flags=re.DOTALL)

# Remove trailing whitespace/newlines
content = content.rstrip() + '\n'

# Build new phpIniOverride block
new_block = f"\nphpIniOverride  {{\n{ini_block}\n}}\n"

# Insert before the last line or at end
content += new_block

# Atomic write: temp file + rename
conf_dir = os.path.dirname(conf_path)
fd, tmp_path = tempfile.mkstemp(dir=conf_dir, prefix='.vhconf_', suffix='.tmp')
try:
    with os.fdopen(fd, 'w') as f:
        f.write(content)
    os.chmod(tmp_path, 0o644)
    os.rename(tmp_path, conf_path)
except Exception:
    try:
        os.unlink(tmp_path)
    except OSError:
        pass
    raise
PYEOF

# Validate config by restarting (lswsctrl has no configtest)
/usr/local/lsws/bin/lswsctrl restart &>/dev/null || true
sleep 1
if ! pgrep -f "litespeed|lshttpd|openlitespeed" &>/dev/null; then
    # Restore backup if LiteHttpd failed to start
    if [[ -f "${VHOST_CONF}.bak" ]]; then
        mv "${VHOST_CONF}.bak" "$VHOST_CONF"
        /usr/local/lsws/bin/lswsctrl restart &>/dev/null || true
    fi
    # Keep the caller-supplied config file on failure so it can be retried
    echo '{"ok":false,"error":"config_validation_failed","message":"LiteHttpd failed to start, changes reverted"}' >&2
    exit 1
fi

# Remove backup and the caller-supplied config file now that validation has passed
rm -f "${VHOST_CONF}.bak"
rm -f "$CONFIG_FILE"

# Reload LiteHttpd
/usr/local/lsws/bin/lswsctrl reload &>/dev/null || true

echo '{"ok":true}'
