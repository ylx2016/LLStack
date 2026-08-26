#!/bin/bash
set -euo pipefail
DOMAIN="" DOC_ROOT="" PHP_VERSION="php83"
while [[ $# -gt 0 ]]; do case "$1" in --domain) DOMAIN="$2"; shift 2 ;; --doc-root) DOC_ROOT="$2"; shift 2 ;; --php) PHP_VERSION="$2"; shift 2 ;; *) shift ;; esac; done
[[ -z "$DOMAIN" || -z "$DOC_ROOT" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }
# Validate PHP version format (prevent path/command injection via unvalidated input)
if ! [[ "$PHP_VERSION" =~ ^php[0-9]+$ ]]; then
    echo '{"ok":false,"error":"invalid_php_version"}' >&2; exit 1
fi
PHP_SHORT="${PHP_VERSION#php}"
COMPOSER=("/opt/remi/php${PHP_SHORT}/root/usr/bin/php" "/usr/local/bin/composer")
# Install composer if not exists
if [[ ! -f /usr/local/bin/composer ]]; then
    PHP_BIN="/opt/remi/php${PHP_SHORT}/root/usr/bin/php"
    SETUP_FILE=$(mktemp /tmp/composer-setup.XXXXXX.php)
    trap 'rm -f "$SETUP_FILE"' EXIT
    EXPECTED_SIG=$(curl -sS https://composer.github.io/installer.sig)
    curl -sS https://getcomposer.org/installer -o "$SETUP_FILE"
    ACTUAL_SIG=$($PHP_BIN -r "echo hash_file('sha384', '$SETUP_FILE');")
    if [[ "$EXPECTED_SIG" != "$ACTUAL_SIG" ]]; then
        rm -f "$SETUP_FILE"
        echo '{"ok":false,"error":"composer_checksum_mismatch"}' >&2; exit 1
    fi
    $PHP_BIN "$SETUP_FILE" --install-dir=/usr/local/bin --filename=composer 2>/dev/null
    rm -f "$SETUP_FILE"
fi
SITE_USER=$(stat -c '%U' "$DOC_ROOT")
cd "$(dirname "$DOC_ROOT")"
rm -rf "$(basename "$DOC_ROOT")"
sudo -u "$SITE_USER" "${COMPOSER[@]}" create-project laravel/laravel "$(basename "$DOC_ROOT")" 2>&1 | tail -3
chown -R "$SITE_USER:$SITE_USER" "$DOC_ROOT"
echo "{\"ok\":true,\"data\":{\"app\":\"laravel\",\"domain\":\"$DOMAIN\"}}"
