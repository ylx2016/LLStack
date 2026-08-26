#!/bin/bash
set -euo pipefail

# Create a new site with LiteHttpd vhost configuration
# Usage: site-create.sh --domain <domain> --user <system_user> --php <php_version> [--aliases <alias1,alias2>]

DOMAIN=""
USER=""
PHP_VERSION="php83"
ALIASES=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)  DOMAIN="$2"; shift 2 ;;
        --user)    USER="$2"; shift 2 ;;
        --php)     PHP_VERSION="$2"; shift 2 ;;
        --aliases) ALIASES="$2"; shift 2 ;;
        *) echo '{"ok": false, "error": "unknown_arg", "message": "Unknown argument: '"$1"'"}' >&2; exit 1 ;;
    esac
done

# Validate
if [[ -z "$DOMAIN" || -z "$USER" ]]; then
    echo '{"ok": false, "error": "missing_args", "message": "--domain and --user are required"}' >&2
    exit 1
fi

# Validate domain format
if ! echo "$DOMAIN" | grep -qP '^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
    echo '{"ok": false, "error": "invalid_domain", "message": "Invalid domain format"}' >&2
    exit 1
fi

# Validate aliases (comma-separated list of valid domain names) — prevents config
# injection into httpd_config.conf and vhconf.conf via unsanitized --aliases.
if [[ -n "$ALIASES" ]]; then
    IFS=',' read -ra ALIAS_LIST <<< "$ALIASES"
    for a in "${ALIAS_LIST[@]}"; do
        a="$(echo "$a" | tr -d '[:space:]')"
        if ! echo "$a" | grep -qP '^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
            echo '{"ok": false, "error": "invalid_alias", "message": "Invalid alias: '"$a"'"}' >&2
            exit 1
        fi
    done
    # Rebuild from the validated, whitespace-stripped list
    ALIASES=$(IFS=,; echo "${ALIAS_LIST[*]}")
fi

# Validate user exists
if ! id "$USER" &>/dev/null; then
    echo '{"ok": false, "error": "user_not_found", "message": "System user '"$USER"' does not exist"}' >&2
    exit 1
fi

# Avoid placing sites under /root/ (700 permissions, nobody can't access)
if [[ "$USER" == "root" ]]; then
    HOME_DIR="/var/www"
else
    HOME_DIR=$(getent passwd "$USER" | cut -d: -f6)
fi
DOC_ROOT="$HOME_DIR/public_html/$DOMAIN"
VHOST_DIR="/usr/local/lsws/conf/vhosts/$DOMAIN"
VHOST_CONF="$VHOST_DIR/vhconf.conf"
LSWS_CONF="/usr/local/lsws/conf/httpd_config.conf"

# Check vhost doesn't already exist
if [[ -d "$VHOST_DIR" ]]; then
    echo '{"ok": false, "error": "domain_exists", "message": "Vhost directory already exists"}' >&2
    exit 1
fi

# 1. Create document root
mkdir -p "$DOC_ROOT"
chown "$USER:$USER" "$DOC_ROOT"
chmod 755 "$DOC_ROOT"

# Create default index
cat > "$DOC_ROOT/index.html" << 'INDEXEOF'
<!DOCTYPE html>
<html><head><title>Welcome</title></head>
<body><h1>Site is ready</h1><p>Upload your files to get started.</p></body>
</html>
INDEXEOF
chown "$USER:$USER" "$DOC_ROOT/index.html"

# 2. Create security .htaccess
cat > "$DOC_ROOT/.htaccess" << 'HTEOF'
# Security headers
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-XSS-Protection "1; mode=block"
Header always set Referrer-Policy "strict-origin-when-cross-origin"

# Block sensitive files
<FilesMatch "^(wp-config\.php|\.env|\.git|\.htpasswd)">
    Require all denied
</FilesMatch>

# Block XML-RPC (WordPress)
<Files xmlrpc.php>
    Require all denied
</Files>

# Block PHP in uploads directory
<IfModule litehttpd_htaccess>
    <FilesMatch "\.php$">
        <If "%{REQUEST_URI} =~ m#/uploads/#">
            Require all denied
        </If>
    </FilesMatch>
</IfModule>
HTEOF
chown "$USER:$USER" "$DOC_ROOT/.htaccess"

# 3. Determine aliases string
ALIAS_CONF=""
if [[ -n "$ALIASES" ]]; then
    ALIAS_CONF="vhAliases                 $ALIASES"
fi

# 3b. Ensure PHP extprocessor exists in httpd_config.conf
PHP_SHORT="${PHP_VERSION//php/}"
LSPHP_PATH="/opt/remi/php${PHP_SHORT}/root/usr/bin/lsphp"
if [[ ! -f "$LSPHP_PATH" ]]; then
    # LiteHttpd ships under /usr/local/lsws — $SERVER_ROOT is NOT defined in this
    # standalone script, so use the absolute path.
    LSPHP_PATH="/usr/local/lsws/lsphp${PHP_SHORT}/bin/lsphp"
fi
if ! grep -q "extprocessor lsphp${PHP_SHORT}" "$LSWS_CONF" 2>/dev/null; then
    cat >> "$LSWS_CONF" << EXTEOF

extprocessor lsphp${PHP_SHORT} {
  type                    lsapi
  address                 uds://tmp/lshttpd/lsphp${PHP_SHORT}.sock
  maxConns                10
  env                     PHP_LSAPI_CHILDREN=10
  env                     PHP_LSAPI_MAX_IDLE=300
  initTimeout             60
  retryTimeout            0
  pcKeepAliveTimeout      5
  respBuffer              0
  autoStart               2
  path                    ${LSPHP_PATH}
  backlog                 100
  instances               1
  priority                0
  memSoftLimit            2047M
  memHardLimit            2047M
  procSoftLimit           1400
  procHardLimit           1500
}
EXTEOF
fi

# 4. Create vhost configuration via template
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RENDER_ARGS=(--domain "$DOMAIN" --doc-root "$DOC_ROOT" --php "$PHP_VERSION")
if [[ -n "$ALIASES" ]]; then
    RENDER_ARGS+=(--aliases "$ALIASES")
fi
"$SCRIPT_DIR/site-vhost-render.sh" "${RENDER_ARGS[@]}" >/dev/null 2>&1 || {
    # Fallback: write minimal vhost config directly if render script fails
    mkdir -p "$VHOST_DIR"
    cat > "$VHOST_CONF" << VHEOF
docRoot                   $DOC_ROOT
vhDomain                  $DOMAIN
${ALIAS_CONF}
enableGzip                1
enableBr                  1
index  {
  useServer               0
  indexFiles               index.php, index.html
}
scripthandler  {
  add                     lsapi:lsphp$PHP_SHORT php
}
rewrite  {
  enable                  1
  autoLoadHtaccess        1
}
phpIniOverride  {
  php_admin_value open_basedir "$DOC_ROOT:/tmp:/var/tmp:/usr/local/lsws/"
  php_admin_flag engine ON
}
VHEOF
}

# 5. Register the vhost and map it onto the Default listener.
# Both edits happen in one Python pass under the shared httpd_config lock, with
# anchored+escaped idempotency checks. A substring check like `grep "map.*$DOMAIN"`
# would treat an existing `map blog.example.com ...` as covering `example.com`
# and silently skip the map line, leaving the new site unreachable on :80.
DOMAIN_MAP="$DOMAIN"
if [[ -n "$ALIASES" ]]; then
    DOMAIN_MAP="$DOMAIN, $ALIASES"
fi

HTTPD_LOCK="/var/lock/llstack-httpd-config.lock"
exec 201>"$HTTPD_LOCK"
flock -w 10 201 || { echo '{"ok":false,"error":"config_locked"}' >&2; exit 1; }

cp "$LSWS_CONF" "${LSWS_CONF}.llstack.bak"

if ! python3 - "$LSWS_CONF" "$DOMAIN" "$DOMAIN_MAP" "$VHOST_DIR" "$VHOST_CONF" << 'PYEOF'
import re, sys

conf_path, domain, domain_map, vhost_dir, vhost_conf = sys.argv[1:6]
with open(conf_path) as f:
    content = f.read()
orig = content
esc = re.escape(domain)

# Register the virtualhost block if this exact name is not already declared.
if not re.search(r'^\s*virtualhost\s+' + esc + r'\s*\{', content, re.M):
    content = content.rstrip() + f"""

virtualhost {domain} {{
  vhRoot                  {vhost_dir}
  configFile              {vhost_conf}
  allowSymbolLink         1
  enableScript             1
  restrained              1
}}
"""

# Map the domain onto the Default listener if this exact domain is not mapped.
m = re.search(r'(listener\s+Default\s*\{)(.*?)(^\})', content, re.DOTALL | re.M)
if not m:
    print("no Default listener block found in httpd_config.conf", file=sys.stderr)
    sys.exit(2)
block = m.group(2)
if not re.search(r'^\s*map\s+' + esc + r'(\s|,|$)', block, re.M):
    block = block.rstrip('\n') + f"\n  map                     {domain} {domain_map}\n"
    content = content[:m.start(2)] + block + content[m.end(2):]

if content == orig:
    # Nothing to do (already fully registered) — not an error.
    sys.exit(0)

with open(conf_path, 'w') as f:
    f.write(content)
PYEOF
then
    mv "${LSWS_CONF}.llstack.bak" "$LSWS_CONF"
    echo '{"ok":false,"error":"httpd_config_update_failed","message":"Could not register vhost/listener map; config restored"}' >&2
    exit 1
fi
rm -f "${LSWS_CONF}.llstack.bak"

# 6. Create log files and the LSCache storage dir the template references
touch "/usr/local/lsws/logs/$DOMAIN.access.log" "/usr/local/lsws/logs/$DOMAIN.error.log"
chmod 640 "/usr/local/lsws/logs/$DOMAIN.access.log" "/usr/local/lsws/logs/$DOMAIN.error.log"
mkdir -p "/usr/local/lsws/cachedata/$DOMAIN"
chown nobody:nobody "/usr/local/lsws/cachedata/$DOMAIN" 2>/dev/null || true
chmod 755 "/usr/local/lsws/cachedata/$DOMAIN"

# 7. Reload (lswsctrl has no configtest; adding a vhost to an existing listener
# takes effect on reload)
/usr/local/lsws/bin/lswsctrl reload &>/dev/null || true

cat << EOF
{"ok": true, "data": {"domain": "$DOMAIN", "doc_root": "$DOC_ROOT", "vhost_conf": "$VHOST_CONF", "php_version": "$PHP_VERSION"}}
EOF
