#!/bin/bash
set -euo pipefail

# Delete a site: vhost config, listener map, logs, cache dir, and optionally files
# Usage: site-delete.sh --domain <domain> [--remove-files]
#
# site-create.sh registers a site in two places — a `virtualhost` block and a
# `map` line inside the listener. Deleting only the block left the map pointing
# at a vhost that no longer exists, which LiteHttpd reports as a config error and
# which makes *every* site on that listener answer 503 after the next reload.
# Both edits are undone here, under the same lock site-create takes, with the
# same restore-on-failure.
#
# Progress goes to stderr; stdout carries only the final JSON document, because
# the backend parses the whole of stdout with json.loads().

DOMAIN=""
REMOVE_FILES=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)       DOMAIN="${2:-}"; shift 2 ;;
        --remove-files) REMOVE_FILES=true; shift ;;
        *) echo '{"ok": false, "error": "unknown_arg"}' >&2; exit 1 ;;
    esac
done

if [[ -z "$DOMAIN" ]]; then
    echo '{"ok": false, "error": "missing_args", "message": "--domain is required"}' >&2
    exit 1
fi

# Validate domain format
if ! echo "$DOMAIN" | grep -qP '^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
    echo '{"ok": false, "error": "invalid_domain"}' >&2
    exit 1
fi

VHOST_DIR="/usr/local/lsws/conf/vhosts/$DOMAIN"
VHOST_CONF="$VHOST_DIR/vhconf.conf"
LSWS_CONF="/usr/local/lsws/conf/httpd_config.conf"
HTTPD_LOCK="/var/lock/llstack-httpd-config.lock"

# 1. Resolve docRoot *before* removing the vhost dir — it is the only record of
# where the files actually live, and --remove-files used to guess by convention.
DOC_ROOT=""
if [[ -f "$VHOST_CONF" ]]; then
    DOC_ROOT=$(grep -oP 'docRoot\s+\K\S+' "$VHOST_CONF" 2>/dev/null | head -1 || echo "")
fi

# 2. Drop the vhost config directory
if [[ -d "$VHOST_DIR" ]]; then
    rm -rf "$VHOST_DIR"
    echo ">>> Removed $VHOST_DIR" >&2
fi

# 3. Unregister from httpd_config.conf: virtualhost block + every listener map
# line whose vhost name is this domain. A map line that merely lists the domain
# as another vhost's alias (`map other.com other.com, $DOMAIN`) is left alone.
if [[ -f "$LSWS_CONF" ]]; then
    exec 201>"$HTTPD_LOCK"
    flock -w 10 201 || { echo '{"ok":false,"error":"config_locked"}' >&2; exit 1; }

    cp "$LSWS_CONF" "${LSWS_CONF}.llstack.bak"

    if ! python3 - "$LSWS_CONF" "$DOMAIN" << 'PYEOF'
import re, sys

conf_path, domain = sys.argv[1:3]
with open(conf_path) as f:
    content = f.read()
esc = re.escape(domain)

# virtualhost <domain> { ... }  — anchored so blog.example.com is not matched
# while deleting example.com
content = re.sub(r'^virtualhost\s+' + esc + r'\s*\{.*?^\}\n?', '',
                 content, flags=re.DOTALL | re.M)

# map <domain> ...  — the first token after `map` is the vhost name
content = re.sub(r'^[ \t]*map[ \t]+' + esc + r'(?=[ \t,\r\n]|$).*\n?', '',
                 content, flags=re.M)

with open(conf_path, 'w') as f:
    f.write(content)
PYEOF
    then
        mv "${LSWS_CONF}.llstack.bak" "$LSWS_CONF"
        echo '{"ok":false,"error":"httpd_config_update_failed","message":"Could not unregister vhost/listener map; config restored"}' >&2
        exit 1
    fi
    rm -f "${LSWS_CONF}.llstack.bak"
    echo ">>> Unregistered $DOMAIN from httpd_config.conf" >&2
fi

# 4. Remove log files, including anything logrotate already rotated
rm -f "/usr/local/lsws/logs/$DOMAIN.access.log" "/usr/local/lsws/logs/$DOMAIN.error.log"
rm -f "/usr/local/lsws/logs/$DOMAIN.access.log."* "/usr/local/lsws/logs/$DOMAIN.error.log."*

# 5. Remove the LSCache storage dir site-create created
rm -rf "/usr/local/lsws/cachedata/$DOMAIN"

# 6. Optionally remove the document root
FILES_REMOVED=false
if [[ "$REMOVE_FILES" == true ]]; then
    # Only ever delete inside a user home, and only a path at least two levels
    # deep: an empty or malformed docRoot must not turn into `rm -rf /home`.
    # `..` is rejected explicitly because it slips through the char class below
    # (`/home/../etc` would otherwise pass).
    if [[ -n "$DOC_ROOT" && "$DOC_ROOT" != *".."* \
          && "$DOC_ROOT" =~ ^/home/[a-zA-Z0-9._-]+/.+ && ! -L "$DOC_ROOT" && -d "$DOC_ROOT" ]]; then
        rm -rf "$DOC_ROOT"
        FILES_REMOVED=true
        echo ">>> Removed docRoot $DOC_ROOT" >&2
    else
        # Fall back to the layout site-create uses when vhconf was already gone
        for home in /home/*/public_html/"$DOMAIN"; do
            if [[ -d "$home" && ! -L "$home" ]]; then
                rm -rf "$home"
                FILES_REMOVED=true
                echo ">>> Removed $home" >&2
            fi
        done
        if [[ "$FILES_REMOVED" != true ]]; then
            echo ">>> WARNING: no docRoot found to remove (docRoot='$DOC_ROOT')" >&2
        fi
    fi
fi

# 7. Reload LiteHttpd (lswsctrl has no configtest)
/usr/local/lsws/bin/lswsctrl reload &>/dev/null || true

echo "{\"ok\": true, \"data\": {\"domain\": \"$DOMAIN\", \"doc_root\": \"$DOC_ROOT\", \"files_removed\": $FILES_REMOVED}}"
