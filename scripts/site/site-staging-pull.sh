#!/bin/bash
set -euo pipefail

# Pull production data into staging site
# Usage: site-staging-pull.sh --staging-domain <domain> --prod-domain <domain> \
#        [--staging-db <db>] [--prod-db <db>]

STAGING_DOMAIN="" PROD_DOMAIN=""
STAGING_DB="" PROD_DB=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --staging-domain) STAGING_DOMAIN="$2"; shift 2 ;;
        --prod-domain)    PROD_DOMAIN="$2"; shift 2 ;;
        --staging-db)     STAGING_DB="$2"; shift 2 ;;
        --prod-db)        PROD_DB="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$STAGING_DOMAIN" || -z "$PROD_DOMAIN" ]]; then
    echo '{"ok":false,"error":"missing_args"}' >&2; exit 1
fi

# Validate domains
validate_domain() {
    echo "$1" | grep -qP '^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
}
if ! validate_domain "$STAGING_DOMAIN" || ! validate_domain "$PROD_DOMAIN"; then
    echo '{"ok":false,"error":"invalid_domain"}' >&2; exit 1
fi

# Resolve paths
STAGING_VHOST="/usr/local/lsws/conf/vhosts/$STAGING_DOMAIN"
PROD_VHOST="/usr/local/lsws/conf/vhosts/$PROD_DOMAIN"

_get_docroot() {
    grep -oP 'docRoot\s+\K\S+' "$1/vhconf.conf" 2>/dev/null || echo ""
}
STAGING_ROOT=$(_get_docroot "$STAGING_VHOST")
PROD_ROOT=$(_get_docroot "$PROD_VHOST")

if [[ -z "$STAGING_ROOT" || -z "$PROD_ROOT" ]]; then
    echo '{"ok":false,"error":"docroot_not_found"}' >&2; exit 1
fi

# Step 1: Sync files from production to staging
echo ">>> Step 1: Pulling files from production..." >&2
rsync -a --delete \
    --exclude='.git' \
    --exclude='wp-config.php' \
    --exclude='.env' \
    --exclude='.user.ini' \
    --exclude='wp-content/debug.log' \
    "$PROD_ROOT/" "$STAGING_ROOT/"

STAGING_OWNER=$(stat -c '%U' "$STAGING_ROOT" 2>/dev/null || echo "root")
chown -R "$STAGING_OWNER:$STAGING_OWNER" "$STAGING_ROOT"
echo "    Files synced: $PROD_ROOT → $STAGING_ROOT" >&2

# Step 2: Pull database
if [[ -n "$STAGING_DB" && -n "$PROD_DB" ]]; then
    echo ">>> Step 2: Pulling database..." >&2
    mysqldump "$PROD_DB" 2>/dev/null | mysql "$STAGING_DB" 2>/dev/null

    # Replace production domain with staging domain
    if command -v wp &>/dev/null && [[ -f "$STAGING_ROOT/wp-config.php" ]]; then
        cd "$STAGING_ROOT"
        wp search-replace "https://$PROD_DOMAIN" "https://$STAGING_DOMAIN" --all-tables --skip-columns=guid --allow-root 2>&1 || true
        wp search-replace "http://$PROD_DOMAIN" "http://$STAGING_DOMAIN" --all-tables --skip-columns=guid --allow-root 2>&1 || true
        echo "    WP domain replaced: $PROD_DOMAIN → $STAGING_DOMAIN" >&2
    else
        mysql "$STAGING_DB" -e "
            UPDATE wp_options SET option_value = REPLACE(option_value, '$PROD_DOMAIN', '$STAGING_DOMAIN')
            WHERE option_name IN ('siteurl', 'home');
        " 2>/dev/null || true
        echo "    wp_options updated" >&2
    fi
    echo "    Database pulled: $PROD_DB → $STAGING_DB" >&2
else
    echo ">>> Step 2: Skipped (no database specified)" >&2
fi

echo '{"ok":true}'
