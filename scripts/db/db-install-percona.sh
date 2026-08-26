#!/bin/bash
set -euo pipefail
# Install Percona Server from the official repo
# Usage: db-install-percona.sh --version <8.0|8.4>
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
[[ -z "$VERSION" ]] && { echo '{"ok":false,"error":"missing_args","message":"--version <8.0|8.4>"}' >&2; exit 1; }

# Validate version (interpolated into percona-release setup targets)
if ! [[ "$VERSION" =~ ^8\.(0|4)$ ]]; then
    echo '{"ok":false,"error":"invalid_version","message":"Supported: 8.0, 8.4"}' >&2; exit 1
fi

# Idempotency: skip if Percona Server is already installed at the
# requested major.minor. --force overrides.
if ! [[ "$FORCE" == true ]] && rpm -q percona-server-server &>/dev/null; then
    INSTALLED=$(rpm -q --queryformat '%{VERSION}' percona-server-server 2>/dev/null | cut -d. -f1,2)
    if [[ "$INSTALLED" == "$VERSION" ]]; then
        echo "{\"ok\":true,\"data\":{\"engine\":\"percona\",\"requested\":\"$VERSION\",\"installed\":\"$INSTALLED\",\"already_installed\":true}}"
        exit 0
    fi
    echo "{\"ok\":false,\"error\":\"version_conflict\",\"message\":\"Percona $INSTALLED is already installed (requested $VERSION); pass --force to reinstall\"}" >&2
    exit 1
fi

# percona-server-server conflicts with mysql-community-server and MariaDB
# (shared /usr/bin/mysql* paths and port 3306).
for pkg in MariaDB-server mariadb-server mysql-community-server; do
    if rpm -q "$pkg" &>/dev/null; then
        echo "{\"ok\":false,\"error\":\"engine_conflict\",\"message\":\"$pkg is already installed; remove it first\"}" >&2
        exit 1
    fi
done

echo ">>> Setting up Percona repository..." >&2
if ! rpm -q percona-release &>/dev/null; then
    if ! dnf install -y "https://repo.percona.com/yum/percona-release-latest.noarch.rpm" >&2 2>&1; then
        echo '{"ok":false,"error":"repo_setup_failed"}' >&2; exit 1
    fi
fi

echo ">>> Enabling Percona Server $VERSION..." >&2
if [[ "$VERSION" == "8.0" ]]; then
    percona-release setup ps80 >&2 2>&1 || { echo '{"ok":false,"error":"percona_setup_failed"}' >&2; exit 1; }
else
    percona-release setup ps-8.4-lts >&2 2>&1 || \
    percona-release setup ps-84-lts >&2 2>&1 || \
    percona-release setup ps84 >&2 2>&1 || \
    { echo '{"ok":false,"error":"percona_84_setup_failed"}' >&2; exit 1; }
fi

echo ">>> Installing Percona Server..." >&2
if ! dnf install -y percona-server-server >&2 2>&1; then
    echo '{"ok":false,"error":"install_failed"}' >&2; exit 1
fi

echo ">>> Starting Percona Server..." >&2
if ! systemctl enable --now mysqld >&2 2>&1; then
    echo '{"ok":false,"error":"start_failed","message":"mysqld did not start"}' >&2; exit 1
fi

# ── Root credentials ──
# Like MySQL, Percona generates a random temporary root password and enables
# validate_password. Panel scripts call bare `mysql`/`mysqldump`, so reset root
# and write /root/.my.cnf (0600) to keep those working.
CNF="/root/.my.cnf"
if [[ ! -f "$CNF" ]]; then
    TEMP_PASS=$(grep 'temporary password' /var/log/mysqld.log 2>/dev/null | tail -1 | awk '{print $NF}')
    NEW_PASS="$(openssl rand -base64 24 | tr -d '\n=')Aa1!"

    if [[ -n "$TEMP_PASS" ]]; then
        echo ">>> Resetting root password..." >&2
        if ! mysql --connect-expired-password -uroot -p"$TEMP_PASS" \
                -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_PASS}';" 2>/dev/null; then
            echo '{"ok":false,"error":"root_reset_failed"}' >&2; exit 1
        fi
    else
        if ! mysql -uroot -e 'SELECT 1;' &>/dev/null; then
            echo '{"ok":false,"error":"root_password_unknown","message":"No temporary password in /var/log/mysqld.log and root is not reachable; set /root/.my.cnf manually"}' >&2
            exit 1
        fi
        # Earlier version had `|| true` here, which on a unix_socket-auth setup
        # would silently leave root with no password while writing one to
        # /root/.my.cnf — every later `mysql` call would then fail.
        if ! mysql -uroot -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_PASS}';" &>/dev/null; then
            echo '{"ok":false,"error":"root_reset_failed","message":"ALTER USER failed; not writing .my.cnf with a password root does not have"}' >&2
            exit 1
        fi
    fi

    umask 077
    cat > "$CNF" <<CNFEOF
[client]
user=root
password="${NEW_PASS}"
CNFEOF
    chmod 600 "$CNF"
    echo ">>> Root credentials written to $CNF" >&2
fi

# Verify the live server's version actually matches what was requested
INSTALLED_VER=""
if mysql -uroot -e "SELECT VERSION();" &>/dev/null; then
    INSTALLED_VER=$(mysql -uroot -N -B -e "SELECT VERSION();" 2>/dev/null | tr -d '\r' | grep -oE '^[0-9]+\.[0-9]+' | head -1)
fi
if [[ -z "$INSTALLED_VER" ]]; then
    echo '{"ok":false,"error":"version_check_failed","message":"Could not determine installed Percona version"}' >&2
    exit 1
fi
if [[ "$INSTALLED_VER" != "$VERSION" ]]; then
    echo "{\"ok\":false,\"error\":\"version_mismatch\",\"data\":{\"requested\":\"$VERSION\",\"installed\":\"$INSTALLED_VER\"}}" >&2
    exit 1
fi

echo ">>> Percona Server $VERSION installed successfully" >&2
printf '{"ok":true,"data":{"engine":"percona","requested":"%s","installed":"%s","credentials":"%s"}}\n' \
    "$VERSION" "${INSTALLED_VER:-unknown}" "$CNF"
