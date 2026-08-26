#!/bin/bash
set -euo pipefail
# Install MariaDB from the official repo
# Usage: db-install-mariadb.sh --version <10.11|11.4|11.8>
#
# Progress goes to stderr; stdout carries only the final JSON document.

VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done
[[ -z "$VERSION" ]] && { echo '{"ok":false,"error":"missing_args","message":"--version <10.11|11.4|11.8>"}' >&2; exit 1; }

# Validate version. This is written into a yum repo file below — an unvalidated
# value containing a newline could inject repo directives (gpgcheck=0, a hostile
# baseurl) and get RPM scriptlets executed as root.
if ! [[ "$VERSION" =~ ^(10\.11|11\.4|11\.8)$ ]]; then
    echo '{"ok":false,"error":"invalid_version","message":"Supported: 10.11, 11.4, 11.8"}' >&2; exit 1
fi

# MariaDB-client and mysql-community-client both own /usr/bin/mysql (RPM file
# conflict), and mariadb.service / mysqld.service both bind 3306.
for pkg in mysql-community-server percona-server-server; do
    if rpm -q "$pkg" &>/dev/null; then
        echo "{\"ok\":false,\"error\":\"engine_conflict\",\"message\":\"$pkg is already installed; remove it first\"}" >&2
        exit 1
    fi
done

MAJOR_VER=$(. /etc/os-release; echo "${VERSION_ID%%.*}")

echo ">>> Setting up MariaDB $VERSION official repository..." >&2
cat > /etc/yum.repos.d/mariadb.repo << REPOEOF
[mariadb]
name = MariaDB $VERSION
baseurl = https://mirror.mariadb.org/yum/$VERSION/rhel/\$releasever/\$basearch
gpgkey = https://supplychain.mariadb.com/MariaDB-Server-GPG-KEY
gpgcheck = 1
enabled = 1
module_hotfixes = 1
REPOEOF

echo ">>> Installing MariaDB $VERSION..." >&2
# Fall back to the distro package only if the upstream repo has nothing for this
# EL release; report which one was actually used so the caller isn't misled.
USED_UPSTREAM=true
if ! dnf install -y MariaDB-server MariaDB-client >&2 2>&1; then
    USED_UPSTREAM=false
    if ! dnf install -y mariadb-server >&2 2>&1; then
        echo '{"ok":false,"error":"install_failed"}' >&2; exit 1
    fi
    echo "    WARNING: upstream repo had no build for EL${MAJOR_VER}; installed the distro package instead" >&2
fi

echo ">>> Starting MariaDB..." >&2
if ! systemctl enable --now mariadb >&2 2>&1; then
    echo '{"ok":false,"error":"start_failed","message":"mariadb did not start"}' >&2; exit 1
fi

# ── Baseline hardening ──
# MariaDB 10.4+ made mysql.user a view, so `DELETE FROM mysql.user` fails ("not
# updatable") — the old form here silently did nothing behind `|| true`. Use
# DROP USER, which works on both. Root keeps unix_socket auth, which is what the
# panel's bare `mysql` calls rely on.
echo ">>> Applying baseline hardening..." >&2
mysql -e "DROP USER IF EXISTS ''@'localhost';" 2>/dev/null || true
mysql -e "DROP USER IF EXISTS ''@'$(hostname)';" 2>/dev/null || true
mysql -e "DROP USER IF EXISTS 'root'@'%';" 2>/dev/null || true
mysql -e "DROP DATABASE IF EXISTS test;" 2>/dev/null || true
mysql -e "FLUSH PRIVILEGES;" 2>/dev/null || true

# Confirm the panel can actually reach the server passwordless (unix_socket)
if ! mysql -e 'SELECT 1;' &>/dev/null; then
    echo '{"ok":false,"error":"root_unreachable","message":"root cannot connect via unix_socket; panel DB features will not work"}' >&2
    exit 1
fi

INSTALLED_VER=""
if command -v mysql &>/dev/null; then
    # `mysql --version` only reports the client; the panel calls bare
    # `mysql` so client==server in practice (same package on EL).
    INSTALLED_VER=$(mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "")
fi
if [[ -n "$INSTALLED_VER" && "$INSTALLED_VER" != "$VERSION" ]]; then
    echo "{\"ok\":false,\"error\":\"version_mismatch\",\"data\":{\"requested\":\"$VERSION\",\"installed\":\"$INSTALLED_VER\"}}" >&2
    exit 1
fi

echo ">>> MariaDB $VERSION installed successfully" >&2
printf '{"ok":true,"data":{"engine":"mariadb","requested":"%s","installed":"%s","upstream_repo":%s}}\n' \
    "$VERSION" "${INSTALLED_VER:-unknown}" "$USED_UPSTREAM"
