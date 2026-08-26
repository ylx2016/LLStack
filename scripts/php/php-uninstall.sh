#!/bin/bash
set -euo pipefail
# Uninstall a PHP version
# Usage: php-uninstall.sh --version <XX>
#
# Refuses while any site still references the version: removing the extprocessor
# while a vhost keeps `add lsapi:lsphpXX php` leaves a dangling handler and every
# site on that version returns 503.
#
# Progress goes to stderr; stdout carries only the final JSON document.

VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --force)   FORCE=true; shift ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done
FORCE="${FORCE:-false}"

[[ -z "$VERSION" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }
# Validate: VERSION goes into a dnf glob and a sed address range
if ! [[ "$VERSION" =~ ^[0-9]{2,3}$ ]]; then
    echo '{"ok":false,"error":"invalid_version","message":"--version must be numeric (e.g. 83)"}' >&2
    exit 1
fi

# Which sites still use this version?
IN_USE=()
for vhconf in /usr/local/lsws/conf/vhosts/*/vhconf.conf; do
    [[ -f "$vhconf" ]] || continue
    if grep -qE "lsapi:lsphp${VERSION}([^0-9]|$)" "$vhconf" 2>/dev/null; then
        IN_USE+=("$(basename "$(dirname "$vhconf")")")
    fi
done

if [[ ${#IN_USE[@]} -gt 0 && "$FORCE" != true ]]; then
    LIST=$(printf '"%s",' "${IN_USE[@]}"); LIST="[${LIST%,}]"
    printf '{"ok":false,"error":"php_in_use","message":"Sites still use PHP %s; switch them first or pass --force","data":{"sites":%s}}\n' \
        "$VERSION" "$LIST" >&2
    exit 1
fi

echo ">>> Removing PHP $VERSION packages..." >&2
dnf remove -y "php${VERSION}-php-*" >&2 2>&1 || true

# Remove extprocessor from httpd_config.conf under the shared lock
LSWS_CONF="/usr/local/lsws/conf/httpd_config.conf"
if [[ -f "$LSWS_CONF" ]]; then
    exec 201>"/var/lock/llstack-httpd-config.lock"
    flock -w 10 201 || { echo '{"ok":false,"error":"config_locked"}' >&2; exit 1; }
    cp "$LSWS_CONF" "${LSWS_CONF}.llstack.bak"
    sed -i "/^extprocessor lsphp${VERSION} {/,/^}/d" "$LSWS_CONF"
    rm -f "${LSWS_CONF}.llstack.bak"
fi

/usr/local/lsws/bin/lswsctrl reload &>/dev/null || true

echo ">>> PHP $VERSION removed" >&2
printf '{"ok":true,"data":{"version":"php%s","was_in_use_by":%s}}\n' \
    "$VERSION" "$([[ ${#IN_USE[@]} -gt 0 ]] && { LIST=$(printf '"%s",' "${IN_USE[@]}"); echo "[${LIST%,}]"; } || echo '[]')"
