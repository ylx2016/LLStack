#!/bin/bash
set -euo pipefail

# WordPress one-click installer (files only — WordPress runs its own setup wizard)
# Usage: app-wordpress.sh --domain <domain> --doc-root <path> [--php <phpXX>] [--locale <locale>]
#
# Progress goes to stderr; stdout carries only the final JSON document.

DOMAIN="" DOC_ROOT="" PHP_VERSION="php83" WP_LOCALE="en_US"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)   DOMAIN="$2"; shift 2 ;;
        --doc-root) DOC_ROOT="$2"; shift 2 ;;
        --php)      PHP_VERSION="$2"; shift 2 ;;
        --locale)   WP_LOCALE="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$DOMAIN" || -z "$DOC_ROOT" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }
[[ ! -d "$DOC_ROOT" ]] && { echo '{"ok":false,"error":"doc_root_not_found"}' >&2; exit 1; }
if ! [[ "$PHP_VERSION" =~ ^php[0-9]+$ ]]; then
    echo '{"ok":false,"error":"invalid_php_version"}' >&2; exit 1
fi
# Locale format: ll_CC or just ll — restrict so it can't be used to inject
# characters into the wp-config later.
if ! [[ "$WP_LOCALE" =~ ^[a-z]{2}(_[A-Z]{2})?$ ]]; then
    echo '{"ok":false,"error":"invalid_locale"}' >&2; exit 1
fi

# Private work dir: writing to a fixed /tmp path as root lets any local user
# pre-create a symlink there and redirect the download/extraction.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# 1. Download WordPress
echo ">>> Downloading WordPress..." >&2
if ! curl -fsSL --retry 3 --max-time 180 "https://wordpress.org/latest.tar.gz" -o "$WORK/wordpress.tar.gz"; then
    echo '{"ok":false,"error":"download_failed"}' >&2; exit 1
fi

# Verify the SHA256 of the download against WordPress.org's published digest.
# Without this, a CDN / mirror compromise serves an arbitrary tarball and the
# installer happily unpacks it as root. The .sha256 file is a 64-char hex
# string + filename, so we extract the first field.
echo ">>> Verifying SHA256..." >&2
if ! EXPECTED=$(curl -fsSL --max-time 30 "https://wordpress.org/latest.tar.gz.sha256" | awk '{print $1}'); then
    echo '{"ok":false,"error":"sha256_download_failed"}' >&2; exit 1
fi
ACTUAL=$(sha256sum "$WORK/wordpress.tar.gz" | awk '{print $1}')
if [[ ! "$EXPECTED" =~ ^[a-f0-9]{64}$ || "$ACTUAL" != "$EXPECTED" ]]; then
    echo '{"ok":false,"error":"sha256_mismatch","message":"downloaded tarball does not match wordpress.org published hash; refusing to install"}' >&2
    exit 1
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
chown -R "$SITE_USER:$SITE_USER" "$DOC_ROOT" 2>/dev/null || true
# Batch the chmod with xargs so a 3000-file WP install doesn't fork 6000
# processes. Use -print0 to handle any future filename-with-space edge case.
find "$DOC_ROOT" -type d -print0 | xargs -0 chmod 755
find "$DOC_ROOT" -type f -print0 | xargs -0 chmod 644

# 4. Deliberately do NOT create wp-config.php.
# Copying wp-config-sample.php would make WordPress skip its setup wizard (it only
# runs setup-config.php when wp-config.php is absent) and fail with "Error
# establishing a database connection" instead of — with no UI path forward. It would
# also ship the sample's placeholder AUTH_KEY/SALT values, which are identical on
# every install and let login cookies and nonces be forged.
# Leaving the sample in place lets the user complete the normal WordPress installer.

# 5. Security .htaccess for WordPress
# Two critical things to be aware of here:
#  (a) LSBruteForce* directives are LiteSpeed Enterprise only — on OpenLiteSpeed
#      they produce a 500 and the whole site goes down. Wrap them in <IfModule>
#      so OLS ignores them silently.
#  (b) The Apache <Require> directive is wrapped in <IfModule mod_authz_core.c>
#      so Apache 2.2 (which uses Order/Allow/Deny) doesn't choke.
cat > "$DOC_ROOT/.htaccess" << 'HTEOF'
# WordPress permalinks
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>

# LiteSpeed Enterprise-only directives: ignored on Apache and OpenLiteSpeed.
# Without the IfModule wrapper, OpenLiteSpeed returns 500 on the first request
# because the directives are unknown.
<IfModule LiteSpeed>
LSBruteForceProtection On
LSBruteForceAllowedAttempts 5
LSBruteForceWindow 300
LSBruteForceAction throttle
LSBruteForceThrottleDuration 60
LSBruteForceProtectPath /wp-login.php
</IfModule>

# Security headers
<IfModule mod_headers.c>
Header always set X-Content-Type-Options "nosniff"
Header always set X-Frame-Options "SAMEORIGIN"
</IfModule>

# Protect sensitive files
<IfModule mod_authz_core.c>
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
</IfModule>
HTEOF
chown "$SITE_USER:$SITE_USER" "$DOC_ROOT/.htaccess" 2>/dev/null || true

# 6. Report the installed version
WP_VER=$(grep 'wp_version =' "$DOC_ROOT/wp-includes/version.php" 2>/dev/null | grep -oP "'[^']+'" | tr -d "'" || echo "unknown")

echo ">>> WordPress files installed — finish setup in the browser" >&2
# Use Python for JSON serialization so user-supplied values containing " or \
# cannot break the contract the backend parses the whole of stdout for.
python3 - "$WP_VER" "$DOMAIN" "$DOC_ROOT" <<'PYEOF'
import json, sys
ver, domain, doc_root = sys.argv[1], sys.argv[2], sys.argv[3]
print(json.dumps({
    "ok": True,
    "data": {
        "app": "wordpress",
        "name": "WordPress",
        "version": ver,
        "domain": domain,
        "doc_root": doc_root,
        "next_step": f"open https://{domain}/ to run the WordPress installer",
    },
}, separators=(",", ":")))
PYEOF
