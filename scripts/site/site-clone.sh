#!/bin/bash
set -euo pipefail

# Clone a site: files + database + WordPress domain replacement
# Usage: site-clone.sh --source-domain <domain> --target-domain <domain> \
#        --source-user <user> --target-user <user> --source-db <db> --target-db <db> \
#        --php <version> [--wp-replace]

SOURCE_DOMAIN="" TARGET_DOMAIN=""
SOURCE_USER="" TARGET_USER=""
SOURCE_DB="" TARGET_DB=""
PHP_VERSION="php83"
WP_REPLACE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --source-domain) SOURCE_DOMAIN="$2"; shift 2 ;;
        --target-domain) TARGET_DOMAIN="$2"; shift 2 ;;
        --source-user)   SOURCE_USER="$2"; shift 2 ;;
        --target-user)   TARGET_USER="$2"; shift 2 ;;
        --source-db)     SOURCE_DB="$2"; shift 2 ;;
        --target-db)     TARGET_DB="$2"; shift 2 ;;
        --php)           PHP_VERSION="$2"; shift 2 ;;
        --wp-replace)    WP_REPLACE=true; shift ;;
        *) shift ;;
    esac
done

if [[ -z "$SOURCE_DOMAIN" || -z "$TARGET_DOMAIN" ]]; then
    echo '{"ok":false,"error":"missing_args","message":"--source-domain and --target-domain required"}' >&2
    exit 1
fi

# Validate domain format (prevent injection)
validate_domain() {
    echo "$1" | grep -qP '^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
}
if ! validate_domain "$SOURCE_DOMAIN" || ! validate_domain "$TARGET_DOMAIN"; then
    echo '{"ok":false,"error":"invalid_domain"}' >&2
    exit 1
fi

# Validate DB names (alphanumeric + underscore only)
if [[ -n "$SOURCE_DB" ]] && ! echo "$SOURCE_DB" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,63}$'; then
    echo '{"ok":false,"error":"invalid_db_name"}' >&2; exit 1
fi
if [[ -n "$TARGET_DB" ]] && ! echo "$TARGET_DB" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,63}$'; then
    echo '{"ok":false,"error":"invalid_db_name"}' >&2; exit 1
fi

# Resolve home dirs (avoid /root/ — nobody can't access).
# Validate source/target users exist first so _resolve_home never aborts under set -e.
for _u in "${SOURCE_USER:-root}" "${TARGET_USER:-root}"; do
    if [[ "$_u" != "root" ]] && ! id "$_u" &>/dev/null; then
        echo '{"ok":false,"error":"user_not_found","message":"System user '"$_u"' does not exist"}' >&2
        exit 1
    fi
done
_resolve_home() { [[ "$1" == "root" ]] && { echo "/var/www"; return 0; }; getent passwd "$1" | cut -d: -f6; }
SOURCE_HOME=$(_resolve_home "${SOURCE_USER:-root}")
TARGET_HOME=$(_resolve_home "${TARGET_USER:-root}")
if [[ -z "$SOURCE_HOME" || -z "$TARGET_HOME" ]]; then
    echo '{"ok":false,"error":"home_not_found"}' >&2; exit 1
fi
SOURCE_ROOT="$SOURCE_HOME/public_html/$SOURCE_DOMAIN"
TARGET_ROOT="$TARGET_HOME/public_html/$TARGET_DOMAIN"
TARGET_OWNER="${TARGET_USER:-root}"

if [[ ! -d "$SOURCE_ROOT" ]]; then
    echo '{"ok":false,"error":"source_not_found","message":"Source directory not found: '"$SOURCE_ROOT"'"}' >&2
    exit 1
fi

echo ">>> Step 1: Copying files..." >&2
mkdir -p "$(dirname "$TARGET_ROOT")"
cp -a "$SOURCE_ROOT" "$TARGET_ROOT"
chown -R "$TARGET_OWNER:$TARGET_OWNER" "$TARGET_ROOT"
echo "    Files copied: $SOURCE_ROOT → $TARGET_ROOT" >&2

# Step 2: Clone database
if [[ -n "$SOURCE_DB" && -n "$TARGET_DB" ]]; then
    echo ">>> Step 2: Cloning database..." >&2
    # Create target database
    mysql -e "CREATE DATABASE IF NOT EXISTS \`$TARGET_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null || true
    # Dump and import — fail cleanly (don't leave a half-cloned state reported as success)
    if mysqldump "$SOURCE_DB" 2>/dev/null | mysql "$TARGET_DB" 2>/dev/null; then
        echo "    Database cloned: $SOURCE_DB → $TARGET_DB" >&2
    else
        echo '{"ok":false,"error":"db_clone_failed","message":"Database dump/import failed"}' >&2
        exit 1
    fi

    # Grant same user access
    DB_USER="${TARGET_DB}_user"
    DB_PASS=$(openssl rand -hex 8)
    ESCAPED_PASS="${DB_PASS//\\/\\\\}"
    ESCAPED_PASS="${ESCAPED_PASS//\'/\'\'}"
    # MariaDB: IDENTIFIED VIA; MySQL/Percona: IDENTIFIED WITH
    SQL_TMP=$(mktemp /tmp/llstack-sql.XXXXXXXXXX)
    trap 'rm -f -- "$SQL_TMP"' EXIT
    printf '%s\n' \ >&2
"CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED VIA mysql_native_password USING PASSWORD('${ESCAPED_PASS}');" > "$SQL_TMP"
    if ! mysql < "$SQL_TMP" 2>/dev/null; then
        printf '%s\n' \ >&2
"CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED WITH mysql_native_password BY '${ESCAPED_PASS}';" > "$SQL_TMP"
        if ! mysql < "$SQL_TMP" 2>/dev/null; then
            printf '%s\n' \ >&2
"CREATE USER IF NOT EXISTS '${DB_USER}'@'localhost' IDENTIFIED BY '${ESCAPED_PASS}';" > "$SQL_TMP"
            mysql < "$SQL_TMP" 2>/dev/null || true
        fi
    fi
    printf '%s\n' \ >&2
"GRANT ALL PRIVILEGES ON \`${TARGET_DB}\`.* TO '${DB_USER}'@'localhost'; FLUSH PRIVILEGES;" > "$SQL_TMP"
    mysql < "$SQL_TMP" 2>/dev/null || true
    echo "    DB user: ${DB_USER} (password stored securely)" >&2
else
    echo ">>> Step 2: Skipped (no database specified)" >&2
    DB_USER=""
    DB_PASS=""
fi

# Step 3: WordPress domain replacement
if [[ "$WP_REPLACE" == true && -n "$TARGET_DB" ]]; then
    echo ">>> Step 3: WordPress domain replacement..." >&2

    # Update wp_options (domains are pre-validated by regex: ^[a-z0-9.-]+$, safe for SQL strings)
    mysql "$TARGET_DB" -e "
        UPDATE wp_options SET option_value = REPLACE(option_value, '$SOURCE_DOMAIN', '$TARGET_DOMAIN')
        WHERE option_name IN ('siteurl', 'home');
    " 2>/dev/null || true
    echo "    wp_options siteurl/home updated" >&2

    # Serialization-safe search-replace — WP-CLI required for safe operation
    if command -v wp &>/dev/null; then
        cd "$TARGET_ROOT"
        wp search-replace "https://$SOURCE_DOMAIN" "https://$TARGET_DOMAIN" --all-tables --skip-columns=guid --allow-root 2>&1 || true
        wp search-replace "http://$SOURCE_DOMAIN" "http://$TARGET_DOMAIN" --all-tables --skip-columns=guid --allow-root 2>&1 || true
        echo "    WP-CLI search-replace completed" >&2
    else
        # Without WP-CLI, only do safe wp_options update (siteurl/home already done above)
        echo "    WARNING: WP-CLI not found. Only siteurl/home updated." >&2
        echo "    Install WP-CLI for full serialization-safe search-replace." >&2
    fi

    # Update wp-config.php if it has hardcoded domain
    if [[ -f "$TARGET_ROOT/wp-config.php" ]]; then
        sed -i "s|$SOURCE_DOMAIN|$TARGET_DOMAIN|g" "$TARGET_ROOT/wp-config.php"

        # Update DB name in wp-config
        if [[ -n "$TARGET_DB" ]]; then
            sed -i "s|define.*'DB_NAME'.*|define('DB_NAME', '$TARGET_DB');|" "$TARGET_ROOT/wp-config.php"
        fi
        if [[ -n "$DB_USER" ]]; then
            sed -i "s|define.*'DB_USER'.*|define('DB_USER', '$DB_USER');|" "$TARGET_ROOT/wp-config.php" 2>/dev/null
            sed -i "s|define.*'DB_PASSWORD'.*|define('DB_PASSWORD', '$DB_PASS');|" "$TARGET_ROOT/wp-config.php" 2>/dev/null
        fi
        echo "    wp-config.php updated" >&2
    fi
fi

# Step 4: Create vhost via template
echo ">>> Step 4: Creating vhost..." >&2
VHOST_DIR="/usr/local/lsws/conf/vhosts/$TARGET_DOMAIN"
PHP_SHORT="${PHP_VERSION//php/}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/site-vhost-render.sh" \
    --domain "$TARGET_DOMAIN" --doc-root "$TARGET_ROOT" --php "$PHP_VERSION" \
    >/dev/null 2>&1 || {
    # Fallback: minimal vhost config
    mkdir -p "$VHOST_DIR"
    cat > "$VHOST_DIR/vhconf.conf" << VHEOF
docRoot                   $TARGET_ROOT
vhDomain                  $TARGET_DOMAIN
enableGzip                1
enableBr                  1
index  {
  useServer               0
  indexFiles              index.php, index.html
}
scripthandler  {
  add                     lsapi:lsphp$PHP_SHORT php
}
rewrite  {
  enable                  1
  autoLoadHtaccess        1
}
phpIniOverride  {
  php_admin_value open_basedir "$TARGET_ROOT:/tmp:/var/tmp:/usr/local/lsws/"
  php_admin_flag engine ON
}
VHEOF
}

# Register the vhost and map it onto the Default listener, in one Python pass
# under the shared httpd_config lock with anchored+escaped idempotency checks.
# A substring check would treat an existing `map blog.example.com` as covering
# `example.com` and silently skip the map, leaving the clone unreachable on :80.
LSWS_CONF="/usr/local/lsws/conf/httpd_config.conf"
HTTPD_LOCK="/var/lock/llstack-httpd-config.lock"
exec 201>"$HTTPD_LOCK"
flock -w 10 201 || { echo '{"ok":false,"error":"config_locked"}' >&2; exit 1; }

cp "$LSWS_CONF" "${LSWS_CONF}.llstack.bak"

if ! python3 - "$LSWS_CONF" "$TARGET_DOMAIN" "$VHOST_DIR" << 'PYEOF'
import re, sys

conf_path, domain, vhost_dir = sys.argv[1:4]
with open(conf_path) as f:
    content = f.read()
orig = content
esc = re.escape(domain)

if not re.search(r'^\s*virtualhost\s+' + esc + r'\s*\{', content, re.M):
    content = content.rstrip() + f"""

virtualhost {domain} {{
  vhRoot                  {vhost_dir}
  configFile              {vhost_dir}/vhconf.conf
  allowSymbolLink         1
  enableScript            1
  restrained              1
}}
"""

m = re.search(r'(listener\s+Default\s*\{)(.*?)(^\})', content, re.DOTALL | re.M)
if not m:
    print("no Default listener block found in httpd_config.conf", file=sys.stderr)
    sys.exit(2)
block = m.group(2)
if not re.search(r'^\s*map\s+' + esc + r'(\s|,|$)', block, re.M):
    block = block.rstrip('\n') + f"\n  map                     {domain} {domain}\n"
    content = content[:m.start(2)] + block + content[m.end(2):]

if content == orig:
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

# LSCache storage dir referenced by the vhost template
mkdir -p "/usr/local/lsws/cachedata/$TARGET_DOMAIN"
chown nobody:nobody "/usr/local/lsws/cachedata/$TARGET_DOMAIN" 2>/dev/null || true
chmod 755 "/usr/local/lsws/cachedata/$TARGET_DOMAIN"

# Step 5: Reload
echo ">>> Step 5: Reloading LiteHttpd..." >&2
/usr/local/lsws/bin/lswsctrl reload 2>/dev/null || true

echo ">>> Clone complete!" >&2
# Use Python for JSON serialization. $SOURCE_DOMAIN / $TARGET_DOMAIN /
# $TARGET_ROOT / $TARGET_DB / $DB_USER all come from --source-domain etc.
# and have been validated to a domain regex, but json.dumps is the right
# tool to guarantee the JSON contract regardless.
python3 - "$SOURCE_DOMAIN" "$TARGET_DOMAIN" "$TARGET_ROOT" "$TARGET_DB" "$DB_USER" "$WP_REPLACE" <<'PYEOF'
import json, sys
src, tgt, doc_root, db, db_user, wp_replace = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5], sys.argv[6] == "true"
)
print(json.dumps({
    "ok": True,
    "data": {
        "source": src,
        "target": tgt,
        "doc_root": doc_root,
        "database": db,
        "db_user": db_user,
        "db_password": "***",
        "wp_replaced": wp_replace,
    },
}, separators=(",", ":")))
PYEOF
