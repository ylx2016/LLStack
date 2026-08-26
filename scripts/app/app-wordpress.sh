#!/bin/bash
set -euo pipefail

# WordPress one-click installer (files only — WordPress runs its own setup wizard)
# Usage: app-wordpress.sh --domain <domain> --doc-root <path> [--php <phpXX>] [--locale <xx_XX>]
#
# Progress goes to stderr; stdout carries only the final JSON document.

DOMAIN=""
DOC_ROOT=""
PHP_VERSION="php83"
WP_LOCALE="en_US"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)   DOMAIN="$2"; shift 2 ;;
        --doc-root) DOC_ROOT="$2"; shift 2 ;;
        --php)      PHP_VERSION="$2"; shift 2 ;;
        --locale)   WP_LOCALE="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

if [[ -z "$DOMAIN" || -z "$DOC_ROOT" ]]; then
    echo '{"ok": false, "error": "missing_args"}' >&2
    exit 1
fi
[[ ! -d "$DOC_ROOT" ]] && { echo '{"ok":false,"error":"doc_root_not_found"}' >&2; exit 1; }

# Private work dir: writing to a fixed /tmp path as root lets any local user
# pre-create a symlink there and redirect the download/extraction.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 1. Download WordPress
echo ">>> Downloading WordPress..." >&2
if ! curl -fsSL --retry 3 --max-time 180 "https://wordpress.org/latest.tar.gz" -o "$WORK/wordpress.tar.gz"; then
    echo '{"ok":false,"error":"download_failed"}' >&2; exit 1
fi
if ! tar xzf "$WORK/wordpress.tar.gz" -C "$WORK" >&2 2>&1; then
    echo '{"ok":false,"error":"extract_failed"}' >&2; exit 1
fi
if [[ ! -f "$WORK/wordpress/index.php" ]]; then
    echo '{"ok":false,"error":"unexpected_archive_layout"}' >&2; exit 1
fi

# 2. Copy into doc_root
if [[ -f "$DOC_ROOT/index.html" ]]; then
    mv "$DOC_ROOT/index.html" "$DOC_ROOT/index.html.bak" 2>/dev/null || true
fi
shopt -s dotglob
cp -a "$WORK/wordpress/." "$DOC_ROOT/"
shopt -u dotglob

# 3. Permissions
SITE_USER=$(stat -c '%U' "$DOC_ROOT" 2>/dev/null || echo root)
chown -R "$SITE_USER:$SITE_USER" "$DOC_ROOT"
find "$DOC_ROOT" -type d -exec chmod 755 {} \;
find "$DOC_ROOT" -type f -exec chmod 644 {} \;

# 4. Deliberately do NOT create wp-config.php.
# Copying wp-config-sample.php would make WordPress skip its setup wizard (it only
# runs setup-config.php when wp-config.php is absent) and fail with "Error
# establishing a database connection" instead — with no UI path forward. It would
# also ship the sample's placeholder AUTH_KEY/SALT values, which are identical on
# every install and let login cookies and nonces be forged.
# Leaving the sample in place lets the user complete the normal WordPress installer.

# 5. Security .htaccess for WordPress
cat > "$DOC_ROOT/.htaccess" << 'HTEOF'
# WordPress permalinks
<IfModule litehttpd_htaccess>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>

# Security headers
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-XSS-Protection "1; mode=block"

# Protect sensitive files
<FilesMatch "^(wp-config\.php|readme\.html|license\.txt)$">
    Require all denied
</FilesMatch>

# Block XML-RPC
<Files xmlrpc.php>
    Require all denied
</Files>

# Protect uploads from PHP execution
<If "%{REQUEST_URI} =~ m#/wp-content/uploads/.*\.php#">
    Require all denied
</If>

# Brute force protection
LSBruteForceProtection On
LSBruteForceAllowedAttempts 5
LSBruteForceWindow 300
LSBruteForceAction throttle
LSBruteForceThrottleDuration 60
LSBruteForceProtectPath /wp-login.php
HTEOF
chown "$SITE_USER:$SITE_USER" "$DOC_ROOT/.htaccess"

# 6. Report the installed version
WP_VER=$(grep 'wp_version =' "$DOC_ROOT/wp-includes/version.php" 2>/dev/null | grep -oP "'[^']+'" | tr -d "'" || echo "unknown")

echo ">>> WordPress files installed — finish setup in the browser" >&2
printf '{"ok":true,"data":{"app":"wordpress","version":"%s","domain":"%s","doc_root":"%s","next_step":"open https://%s/ to run the WordPress installer"}}\n' \
    "$WP_VER" "$DOMAIN" "$DOC_ROOT" "$DOMAIN"
