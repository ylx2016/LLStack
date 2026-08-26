#!/bin/bash
set -euo pipefail

# Standalone Laravel installer (composer create-project).
#
# Historical context: this predates app-install.sh's manifest-driven install.
# A previous rewrite of this script (a) silently dropped unknown args,
# (b) redirected composer output to stdout (breaking the JSON contract the
# backend parses the whole of stdout for), (c) ran `rm -rf` on the doc-root
# before the install (so an interrupted install left the site empty with no
# rollback), (d) skipped the SITE_USER fallback used by the other app
# scripts, and (e) emitted its own JSON without escaping. All five are fixed
# here. Use app-install.sh + the laravel manifest when possible — this
# standalone entrypoint is kept for parity with the panel API.
#
# Progress goes to stderr; stdout carries only the final JSON document.

DOMAIN="" DOC_ROOT="" PHP_VERSION="php83"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)   DOMAIN="$2"; shift 2 ;;
        --doc-root) DOC_ROOT="$2"; shift 2 ;;
        --php)      PHP_VERSION="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg","message":"unrecognised argument"}' >&2; exit 1 ;;
    esac
done

[[ -z "$DOMAIN" || -z "$DOC_ROOT" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }

# Validate PHP version format (prevent path/command injection via unvalidated input)
if ! [[ "$PHP_VERSION" =~ ^php[0-9]+$ ]]; then
    echo '{"ok":false,"error":"invalid_php_version"}' >&2; exit 1
fi

PHP_SHORT="${PHP_VERSION#php}"
PHP_BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"

# Install composer if it isn't on the system
if [[ ! -x /usr/local/bin/composer ]]; then
    if ! command -v "$PHP_BIN" &>/dev/null; then
        echo '{"ok":false,"error":"php_not_found","message":"'"$PHP_BIN"' is not installed"}' >&2
        exit 1
    fi
    SETUP_FILE=$(mktemp); mv "$SETUP_FILE" "${SETUP_FILE}.php"; SETUP_FILE="${SETUP_FILE}.php"
    # GNU mktemp requires the template to end in X; rename after creation.
    trap 'rm -f "$SETUP_FILE"' EXIT
    # -fS so a non-2xx response is treated as failure instead of a saved
    # HTML error page. -L follows the redirect from /installer to the actual
    # tagged download.
    if ! curl -fsSL https://getcomposer.org/installer -o "$SETUP_FILE"; then
        echo '{"ok":false,"error":"composer_download_failed"}' >&2; exit 1
    fi
    EXPECTED_SIG=$(curl -fsSL https://composer.github.io/installer.sig || true)
    # Pass the path via $argv instead of interpolating into PHP source —
    # $SETUP_FILE could in theory contain a single quote.
    ACTUAL_SIG=$("$PHP_BIN" -r 'echo hash_file("sha384", $argv[1]);' -- "$SETUP_FILE")
    if [[ "$EXPECTED_SIG" != "$ACTUAL_SIG" || -z "$EXPECTED_SIG" ]]; then
        echo '{"ok":false,"error":"composer_checksum_mismatch"}' >&2; exit 1
    fi
    if ! "$PHP_BIN" "$SETUP_FILE" --install-dir=/usr/local/bin --filename=composer >&2; then
        echo '{"ok":false,"error":"composer_install_failed"}' >&2; exit 1
    fi
    rm -f "$SETUP_FILE"
fi

# Resolve site user. Fall back to root only if stat really can't tell — the
# original script had no fallback and would crash with an unhelpful "sudo -u"
# error if stat failed for any reason.
SITE_USER=$(stat -c '%U' "$DOC_ROOT" 2>/dev/null || echo root)
[[ -z "$SITE_USER" ]] && SITE_USER=root

# Build into a staging dir and move the result in. The old version `rm -rf`'d
# the doc-root first, so an interrupted create-project left the site gone with
# no rollback path.
STAGING=$(mktemp -d)
trap 'rm -rf "$STAGING"' EXIT

echo ">>> Running composer create-project laravel/laravel..." >&2
if ! sudo -u "$SITE_USER" /usr/local/bin/composer create-project --no-interaction --no-progress laravel/laravel "$STAGING" >&2; then
    echo '{"ok":false,"error":"composer_create_project_failed"}' >&2
    exit 1
fi

# Move staged files into the doc-root. Use `cp -a` rather than `mv` so a
# pre-existing doc-root (which the operator may have seeded with index.html
# or .htaccess that site-create.sh placed there) is preserved as the base and
# only missing files are added.
shopt -s dotglob nullglob
cp -an "$STAGING"/* "$DOC_ROOT"/ 2>/dev/null || cp -a "$STAGING"/. "$DOC_ROOT"/
shopt -u dotglob nullglob
chown -R "$SITE_USER:$SITE_USER" "$DOC_ROOT" 2>/dev/null || true

# Generate APP_KEY — the .env shipped by Laravel needs this. Failure is
# surfaced instead of being silently swallowed by the previous `|| true`.
if [[ -f "$DOC_ROOT/artisan" ]]; then
    if ! sudo -u "$SITE_USER" "$PHP_BIN" "$DOC_ROOT/artisan" key:generate --force >&2 2>&1; then
        echo '{"ok":false,"error":"key_generate_failed","message":"artisan key:generate failed; Laravel site will return 500 until APP_KEY is set"}' >&2
        exit 1
    fi
fi

# Use Python for JSON serialization so user-supplied values containing " or \
# cannot break the contract the backend parses the whole of stdout for.
python3 - "$APP_NAME" "$DOMAIN" "$DOC_ROOT" <<'PYEOF'
import json, sys
domain, doc_root = sys.argv[1], sys.argv[2]
print(json.dumps({
    "ok": True,
    "data": {
        "app": "laravel",
        "name": "Laravel",
        "domain": domain,
        "doc_root": doc_root,
    },
}, separators=(",", ":")))
PYEOF
