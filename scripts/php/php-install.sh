#!/bin/bash
set -euo pipefail

# Install a PHP version via REMI with php-litespeed SAPI
# Usage: php-install.sh --version <XX> (e.g. 83 for PHP 8.3)

VERSION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        *) echo '{"ok": false, "error": "unknown_arg"}' >&2; exit 1 ;;
    esac
done

if [[ -z "$VERSION" ]]; then
    echo '{"ok": false, "error": "missing_args", "message": "--version is required (e.g. 83)"}' >&2
    exit 1
fi

# Validate version format (defense in depth — VERSION is interpolated into dnf package
# names, the extprocessor config block, and the php.ini path)
if ! [[ "$VERSION" =~ ^[0-9]+$ ]]; then
    echo '{"ok": false, "error": "invalid_version", "message": "--version must be numeric (e.g. 83)"}' >&2
    exit 1
fi

PKG_PREFIX="php${VERSION}"
LSPHP_PATH="/opt/remi/${PKG_PREFIX}/root/usr/bin/lsphp"
LSWS_CONF="/usr/local/lsws/conf/httpd_config.conf"

# Check if already installed
if [[ -f "$LSPHP_PATH" ]]; then
    echo '{"ok": false, "error": "already_installed", "message": "PHP '"$VERSION"' is already installed"}' >&2
    exit 1
fi

# Check REMI repo is available
if ! dnf repolist 2>/dev/null | grep -q remi; then
    echo '{"ok": false, "error": "remi_not_found", "message": "REMI repository not configured"}' >&2
    exit 1
fi

# 1. Install PHP + litespeed SAPI + CLI + common extensions
dnf install -y \
    "${PKG_PREFIX}-php-litespeed" \
    "${PKG_PREFIX}-php-cli" \
    "${PKG_PREFIX}-php-mysqlnd" \
    "${PKG_PREFIX}-php-pgsql" \
    "${PKG_PREFIX}-php-gd" \
    "${PKG_PREFIX}-php-mbstring" \
    "${PKG_PREFIX}-php-xml" \
    "${PKG_PREFIX}-php-curl" \
    "${PKG_PREFIX}-php-zip" \
    "${PKG_PREFIX}-php-intl" \
    "${PKG_PREFIX}-php-bcmath" \
    "${PKG_PREFIX}-php-opcache" \
    "${PKG_PREFIX}-php-soap" \
    "${PKG_PREFIX}-php-sodium" \
    >&2 2>&1 || true

# Verify installation
if [[ ! -f "$LSPHP_PATH" ]]; then
    echo '{"ok": false, "error": "install_failed", "message": "lsphp binary not found after install"}' >&2
    exit 1
fi

# 2. Add extprocessor to httpd_config.conf (if not exists)
if ! grep -q "extprocessor lsphp${VERSION}" "$LSWS_CONF" 2>/dev/null; then
    cat >> "$LSWS_CONF" << EXTEOF

extprocessor lsphp${VERSION} {
  type                    lsapi
  address                 uds://tmp/lshttpd/lsphp${VERSION}.sock
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

# 3. Set sensible php.ini defaults
INI_PATH="/etc/opt/remi/${PKG_PREFIX}/php.ini"
if [[ -f "$INI_PATH" ]]; then
    sed -i 's/^memory_limit = .*/memory_limit = 256M/' "$INI_PATH"
    sed -i 's/^upload_max_filesize = .*/upload_max_filesize = 64M/' "$INI_PATH"
    sed -i 's/^post_max_size = .*/post_max_size = 64M/' "$INI_PATH"
    sed -i 's/^max_execution_time = .*/max_execution_time = 300/' "$INI_PATH"
    sed -i 's/^max_input_time = .*/max_input_time = 300/' "$INI_PATH"
fi

# 4. Reload LiteHttpd
if true; then  # lswsctrl has no configtest — reload unconditionally
    /usr/local/lsws/bin/lswsctrl reload &>/dev/null || true
fi

# 5. Get installed extensions (use CLI php binary, not lsphp which outputs help)
PHP_CLI="/opt/remi/${PKG_PREFIX}/root/usr/bin/php"
if [[ -f "$PHP_CLI" ]]; then
    EXTENSIONS=$($PHP_CLI -m 2>/dev/null | grep -v '^\[' | grep -v '^$' | sort | tr '\n' ',' | sed 's/,$//')
else
    EXTENSIONS=$(rpm -ql ${PKG_PREFIX}-php-* 2>/dev/null | grep '\.so$' | xargs -I{} basename {} .so | sort -u | tr '\n' ',' | sed 's/,$//')
fi

DISPLAY="PHP ${VERSION:0:1}.${VERSION:1}"

# Use Python for JSON serialization. $LSPHP_PATH / $EXTENSIONS are
# system-controlled, but going through json.dumps keeps the contract
# consistent with the rest of the panel.
python3 - "php${VERSION}" "$DISPLAY" "$LSPHP_PATH" "$EXTENSIONS" <<'PYEOF'
import json, sys
version, display, lsphp, exts = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
print(json.dumps({
    "ok": True,
    "data": {
        "version": version,
        "display": display,
        "lsphp_path": lsphp,
        "extensions": exts,
    },
}, separators=(",", ":")))
PYEOF
