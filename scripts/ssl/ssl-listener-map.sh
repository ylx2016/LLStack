#!/bin/bash
set -euo pipefail

# Ensure SSL listener exists in httpd_config.conf and map domain to it
# Usage: ssl-listener-map.sh --domain <domain> [--remove]
# This enables SNI — each domain gets its own vhssl block, the SSL listener maps them

DOMAIN=""
REMOVE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --remove) REMOVE=true; shift ;;
        *) shift ;;
    esac
done

[[ -z "$DOMAIN" ]] && { echo '{"ok":false,"error":"missing_domain"}' >&2; exit 1; }

# Validate domain
if ! echo "$DOMAIN" | grep -qP '^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
    echo '{"ok":false,"error":"invalid_domain"}' >&2; exit 1
fi

LSWS_CONF="/usr/local/lsws/conf/httpd_config.conf"
[[ ! -f "$LSWS_CONF" ]] && { echo '{"ok":false,"error":"config_not_found"}' >&2; exit 1; }

# Lock to prevent concurrent config modifications
LOCK_FILE="/var/lock/llstack-httpd-config.lock"
exec 200>"$LOCK_FILE"
flock -w 10 200 || { echo '{"ok":false,"error":"config_locked"}' >&2; exit 1; }

# Backup
cp "$LSWS_CONF" "${LSWS_CONF}.bak"

python3 - "$LSWS_CONF" "$DOMAIN" "$REMOVE" << 'PYEOF'
import re, sys

conf_path = sys.argv[1]
domain = sys.argv[2]
remove = sys.argv[3] == "True"

with open(conf_path) as f:
    content = f.read()

# 1. Ensure "listener SSL" block exists (port 443)
if 'listener SSL' not in content and not remove:
    # Use domain's own cert as default for the SSL listener
    # (each vhost also has its own vhssl block for SNI)
    import os as _os
    domain_cert_dir = f"/usr/local/lsws/conf/ssl/{domain}"
    panel_cert_dir = "/usr/local/lsws/conf/ssl/panel"
    if _os.path.isfile(f"{domain_cert_dir}/privkey.pem"):
        cert_dir = domain_cert_dir
    elif _os.path.isfile(f"{panel_cert_dir}/privkey.pem"):
        cert_dir = panel_cert_dir
    else:
        print(f"No SSL cert found for listener default", file=sys.stderr)
        sys.exit(1)

    ssl_listener = f"""
listener SSL {{
  address                 *:443
  secure                  1
  keyFile                 {cert_dir}/privkey.pem
  certFile                {cert_dir}/fullchain.pem
  certChain               1
  sslProtocol             24
  enableSpdy              15
  enableStapling          1
  map                     {domain} {domain}
}}
"""
    # Insert after last listener block or before first virtualHost
    vh_match = re.search(r'^virtualhost\s', content, re.MULTILINE)
    if vh_match:
        pos = vh_match.start()
        content = content[:pos] + ssl_listener + "\n" + content[pos:]
    else:
        content += ssl_listener
else:
    # 2. SSL listener exists — add or remove domain mapping
    ssl_pattern = r'(listener SSL\s*\{.*?)(^\})'
    ssl_match = re.search(ssl_pattern, content, re.DOTALL | re.MULTILINE)

    if ssl_match:
        ssl_block = ssl_match.group(1)

        if remove:
            # Remove map line for this domain (word-boundary match)
            ssl_block = re.sub(r'\s*map\s+' + re.escape(domain) + r'\s+[^\n]*\n?', '\n', ssl_block)
        else:
            # Check if domain already mapped (exact match, not substring)
            if re.search(r'\bmap\s+' + re.escape(domain) + r'\s', ssl_block):
                pass  # Already mapped
            else:
                # Add map entry before closing brace
                ssl_block += f"  map                     {domain} {domain}\n"

        content = content[:ssl_match.start()] + ssl_block + "}" + content[ssl_match.end():]

with open(conf_path, 'w') as f:
    f.write(content)
PYEOF

# Validate config by attempting a graceful restart
# (lswsctrl has no configtest subcommand — restart validates implicitly)
/usr/local/lsws/bin/lswsctrl restart &>/dev/null || true
sleep 2

# Check if LiteHttpd is still running after restart
# (pgrep uses ERE — use | alternation, not \| which is a literal pipe and never matches)
if ! pgrep -f 'litespeed|lshttpd|openlitespeed' &>/dev/null; then
    # Rollback on failure
    mv "${LSWS_CONF}.bak" "$LSWS_CONF"
    /usr/local/lsws/bin/lswsctrl restart &>/dev/null || true
    echo '{"ok":false,"error":"config_validation_failed"}' >&2; exit 1
fi

rm -f "${LSWS_CONF}.bak"

echo '{"ok":true}'
