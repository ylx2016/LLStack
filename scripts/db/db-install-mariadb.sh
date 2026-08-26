#!/bin/bash
set -euo pipefail
# Install MariaDB from the official repo
# Usage: db-install-mariadb.sh --version <10.11|11.4|11.8>
#
# Progress goes to stderr; stdout carries only the final JSON document.

VERSION=""
FORCE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --force)   FORCE=true; shift ;;
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

# Idempotency: the setup wizard re-runs each step on retry. If MariaDB
# server is already installed at the requested major.minor, treat that
# as success so the wizard can move on. --force forces a real reinstall.
if ! [[ "$FORCE" == true ]] && rpm -q MariaDB-server &>/dev/null; then
    INSTALLED=$(rpm -q --queryformat '%{VERSION}' MariaDB-server 2>/dev/null || echo "")
    if [[ "$INSTALLED" == "$VERSION" ]]; then
        echo "{\"ok\":true,\"data\":{\"engine\":\"mariadb\",\"requested\":\"$VERSION\",\"installed\":\"$INSTALLED\",\"already_installed\":true}}"
        exit 0
    fi
    # Different version installed: don't reinstall over it — the operator
    # must choose. Up to them via the UI; here we just report.
    echo "{\"ok\":false,\"error\":\"version_conflict\",\"message\":\"MariaDB $INSTALLED is already installed (requested $VERSION); pass --force to reinstall\"}" >&2
    exit 1
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
# Prefer the live server's VERSION() — that is what the panel actually
# talks to. The fallback (mysql --version) is the client banner, which
# on MariaDB looks like "Ver 15.1 Distrib 10.11.19-MariaDB" — the first
# "X.Y" is the protocol version (15.1), not the server, so a naive
# `[0-9]+\.[0-9]+` would catch the wrong number. Match after "Distrib"
# to get the real version; fall back to the first X.Y only if there is
# no "Distrib" (the MySQL/Percona banner has no "Distrib" and starts
# with the real version).
if mysql -uroot -e "SELECT VERSION();" &>/dev/null; then
    INSTALLED_VER=$(mysql -uroot -N -B -e "SELECT VERSION();" 2>/dev/null \
        | tr -d '\r' | grep -oE '^[0-9]+\.[0-9]+' | head -1)
elif command -v mysql &>/dev/null; then
    INSTALLED_VER=$(mysql --version 2>/dev/null \
        | grep -oE 'Distrib [0-9]+\.[0-9]+' | head -1 \
        | sed -E 's/Distrib //')
    [[ -z "$INSTALLED_VER" ]] && INSTALLED_VER=$(mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)
fi
if [[ -n "$INSTALLED_VER" && "$INSTALLED_VER" != "$VERSION" ]]; then
    echo "{\"ok\":false,\"error\":\"version_mismatch\",\"data\":{\"requested\":\"$VERSION\",\"installed\":\"$INSTALLED_VER\"}}" >&2
    exit 1
fi

echo ">>> MariaDB $VERSION installed successfully" >&2
printf '{"ok":true,"data":{"engine":"mariadb","requested":"%s","installed":"%s","upstream_repo":%s}}\n' \
    "$VERSION" "${INSTALLED_VER:-unknown}" "$USED_UPSTREAM"
