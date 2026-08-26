#!/bin/bash
set -euo pipefail

# Install one PHP extension for one installed PHP version
# Usage: php-ext-install.sh --version <XX> --ext <name>
#
# REMI splits extensions across two naming schemes: bundled ones are
# phpXX-php-<name> (gd, intl, soap …) while everything shipped through PECL is
# phpXX-php-pecl-<name> (redis, imagick, apcu, mongodb …). Guessing only one
# scheme fails for whichever half you did not guess, so both are tried.
#
# Progress and dnf output go to stderr; stdout carries only the final JSON
# document, because the backend parses the whole of stdout with json.loads().

VERSION="" EXT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:-}"; shift 2 ;;
        --ext)     EXT="${2:-}"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

if [[ -z "$VERSION" || -z "$EXT" ]]; then
    echo '{"ok":false,"error":"missing_args","message":"--version and --ext are required"}' >&2
    exit 1
fi

# VERSION and EXT are interpolated into package names and the JSON reply
if ! [[ "$VERSION" =~ ^[0-9]{2,3}$ ]]; then
    echo '{"ok":false,"error":"invalid_version","message":"--version must be numeric (e.g. 83)"}' >&2
    exit 1
fi
if ! [[ "$EXT" =~ ^[a-zA-Z0-9_-]{1,40}$ ]]; then
    echo '{"ok":false,"error":"invalid_ext","message":"--ext must match [a-zA-Z0-9_-]"}' >&2
    exit 1
fi

PKG_PREFIX="php${VERSION}"
PHP_CLI="/opt/remi/${PKG_PREFIX}/root/usr/bin/php"

# Refuse when the version is absent: dnf would happily pull the entire PHP stack
# in as a dependency, giving the panel a version it never provisioned.
if ! rpm -q "${PKG_PREFIX}-php-common" &>/dev/null; then
    echo "{\"ok\":false,\"error\":\"php_version_not_installed\",\"message\":\"PHP ${VERSION} is not installed\"}" >&2
    exit 1
fi

# Already present? Report the package that provides it instead of reinstalling.
for pkg in "${PKG_PREFIX}-php-${EXT}" "${PKG_PREFIX}-php-pecl-${EXT}"; do
    if rpm -q "$pkg" &>/dev/null; then
        echo ">>> $pkg already installed" >&2
        echo "{\"ok\":true,\"data\":{\"version\":\"${PKG_PREFIX}\",\"extension\":\"$EXT\",\"package\":\"$pkg\",\"already_installed\":true,\"loaded\":true}}"
        exit 0
    fi
done

INSTALLED_PKG=""
for pkg in "${PKG_PREFIX}-php-${EXT}" "${PKG_PREFIX}-php-pecl-${EXT}"; do
    echo ">>> Trying $pkg ..." >&2
    if dnf install -y "$pkg" >&2; then
        INSTALLED_PKG="$pkg"
        break
    fi
    echo ">>> $pkg not available" >&2
done

if [[ -z "$INSTALLED_PKG" ]]; then
    echo "{\"ok\":false,\"error\":\"package_not_found\",\"message\":\"Neither ${PKG_PREFIX}-php-${EXT} nor ${PKG_PREFIX}-php-pecl-${EXT} could be installed\"}" >&2
    exit 1
fi

# An installed package whose module never loads (missing .ini, ABI mismatch) is
# the failure mode that silently produces "installed but not working", so the
# caller is told which of the two happened.
# The match is loose on word boundaries because `php -m` prints the module's own
# name, not the package's: opcache reports as "Zend OPcache". EXT is validated
# above, so it is safe to splice into the pattern.
LOADED=false
if [[ -x "$PHP_CLI" ]] && "$PHP_CLI" -m 2>/dev/null | grep -qiE "(^|[^a-zA-Z0-9])${EXT}([^a-zA-Z0-9]|$)"; then
    LOADED=true
fi

# Extensions only reach the running workers after lsphp restarts
/usr/local/lsws/bin/lswsctrl reload &>/dev/null || true

echo ">>> Installed $INSTALLED_PKG (loaded=$LOADED)" >&2
echo "{\"ok\":true,\"data\":{\"version\":\"${PKG_PREFIX}\",\"extension\":\"$EXT\",\"package\":\"$INSTALLED_PKG\",\"already_installed\":false,\"loaded\":$LOADED}}"
