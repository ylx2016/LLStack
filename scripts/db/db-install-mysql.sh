#!/bin/bash
set -euo pipefail
# Install MySQL from the official Oracle repo
# Usage: db-install-mysql.sh --version <8.0|8.4|9.x>
#
# Progress goes to stderr; stdout carries only the final JSON document.

VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done
[[ -z "$VERSION" ]] && { echo '{"ok":false,"error":"missing_args","message":"--version <8.0|8.4|9.x>"}' >&2; exit 1; }

# Validate version (interpolated into repo names and package selection)
if ! [[ "$VERSION" =~ ^(8\.0|8\.4|9\.[0-9]+)$ ]]; then
    echo '{"ok":false,"error":"invalid_version","message":"Supported: 8.0, 8.4, 9.x"}' >&2; exit 1
fi

# Refuse if a conflicting engine is already installed: MariaDB-client and
# mysql-community-client both own /usr/bin/mysql (RPM file conflict), and
# mariadb.service / mysqld.service both bind 3306.
for pkg in MariaDB-server mariadb-server percona-server-server; do
    if rpm -q "$pkg" &>/dev/null; then
        echo "{\"ok\":false,\"error\":\"engine_conflict\",\"message\":\"$pkg is already installed; remove it first\"}" >&2
        exit 1
    fi
done

MAJOR_VER=$(. /etc/os-release; echo "${VERSION_ID%%.*}")

# dnf5 (EL10) replaced `config-manager --enable X` with `config-manager setopt X.enabled=1`
repo_set() {  # repo_set <repo> <0|1>
    if dnf --version 2>/dev/null | head -1 | grep -q '^dnf5'; then
        dnf config-manager setopt "$1.enabled=$2" 2>/dev/null || true
    else
        [[ "$2" == "1" ]] && dnf config-manager --enable "$1" 2>/dev/null || true
        [[ "$2" == "0" ]] && dnf config-manager --disable "$1" 2>/dev/null || true
    fi
}

echo ">>> Setting up MySQL $VERSION official repository..." >&2
if ! rpm -q mysql84-community-release &>/dev/null && ! rpm -q mysql80-community-release &>/dev/null; then
    INSTALLED_REPO=false
    for REL in 5 4 3 2 1; do
        if dnf install -y "https://dev.mysql.com/get/mysql84-community-release-el${MAJOR_VER}-${REL}.noarch.rpm" >&2 2>&1; then
            INSTALLED_REPO=true
            break
        fi
    done
    if [[ "$INSTALLED_REPO" != true ]]; then
        echo '{"ok":false,"error":"repo_setup_failed","message":"Could not install the MySQL community release RPM"}' >&2
        exit 1
    fi
fi

echo ">>> Enabling MySQL $VERSION repository..." >&2
for r in mysql80-community mysql-8.4-lts-community mysql-innovation-community \
         mysql-tools-8.4-lts-community mysql-tools-innovation-community; do
    repo_set "$r" 0
done

case "$VERSION" in
    8.0) repo_set mysql80-community 1 ;;
    8.4) repo_set mysql-8.4-lts-community 1; repo_set mysql-tools-8.4-lts-community 1 ;;
    *)   repo_set mysql-innovation-community 1; repo_set mysql-tools-innovation-community 1 ;;
esac

echo ">>> Installing MySQL $VERSION..." >&2
if ! dnf install -y mysql-community-server >&2 2>&1; then
    echo '{"ok":false,"error":"install_failed"}' >&2
    exit 1
fi

echo ">>> Starting MySQL..." >&2
if ! systemctl enable --now mysqld >&2 2>&1; then
    echo '{"ok":false,"error":"start_failed","message":"mysqld did not start"}' >&2
    exit 1
fi

# ── Root credentials ──
# MySQL generates a random temporary root password and enables validate_password.
# Every panel script calls bare `mysql`/`mysqldump`, which only works passwordless
# under MariaDB's unix_socket auth. Reset root to a generated password and write it
# to /root/.my.cnf (0600) so those bare calls keep working here too.
CNF="/root/.my.cnf"
if [[ ! -f "$CNF" ]]; then
    TEMP_PASS=$(grep 'temporary password' /var/log/mysqld.log 2>/dev/null | tail -1 | awk '{print $NF}')
    # base64 alphabet has no quotes/backslashes; the suffix guarantees the default
    # MEDIUM validate_password policy is satisfied (upper, lower, digit, special).
    NEW_PASS="$(openssl rand -base64 24 | tr -d '\n=')Aa1!"

    if [[ -n "$TEMP_PASS" ]]; then
        echo ">>> Resetting root password..." >&2
        if ! mysql --connect-expired-password -uroot -p"$TEMP_PASS" \
                -e "ALTER USER 'root'@'localhost' IDENTIFIED BY '${NEW_PASS}';" 2>/dev/null; then
            echo '{"ok":false,"error":"root_reset_failed","message":"Could not reset the MySQL root password"}' >&2
            exit 1
        fi
    else
        # No temp password in the log (re-install over existing datadir): only proceed
        # if root is already reachable without one.
        if ! mysql -uroot -e 'SELECT 1;' &>/dev/null; then
            echo '{"ok":false,"error":"root_password_unknown","message":"No temporary password in /var/log/mysqld.log and root is not reachable; set /root/.my.cnf manually"}' >&2
            exit 1
        fi
        # The earlier version had `|| true` here, which swallowed a real ALTER
        # failure (e.g. on systems where root authenticates via unix_socket):
        # the script would then write a NEW password to /root/.my.cnf that
        # root does not actually have, locking out every later mysql call.
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

# Verify the installed major.minor actually matches what was requested.
# The earlier version only checked 8.x branches and used `mysql --version` which
# returns the client version (matched only because the client and server are
# from the same package on EL); we now query the live server.
INSTALLED_VER=""
if mysql -uroot -e "SELECT VERSION();" &>/dev/null; then
    INSTALLED_VER=$(mysql -uroot -N -B -e "SELECT VERSION();" 2>/dev/null | tr -d '\r' | grep -oE '^[0-9]+\.[0-9]+' | head -1)
elif command -v mysql &>/dev/null; then
    # Fallback: client banner — only acceptable if we cannot reach the server
    INSTALLED_VER=$(mysql --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1 || echo "")
fi
if [[ -n "$INSTALLED_VER" && "$INSTALLED_VER" != "$VERSION" ]]; then
    echo "{\"ok\":false,\"error\":\"version_mismatch\",\"data\":{\"requested\":\"$VERSION\",\"installed\":\"$INSTALLED_VER\"}}" >&2
    exit 1
fi

echo ">>> MySQL $VERSION installed successfully" >&2
printf '{"ok":true,"data":{"engine":"mysql","requested":"%s","installed":"%s","credentials":"%s"}}\n' \
    "$VERSION" "${INSTALLED_VER:-unknown}" "$CNF"
