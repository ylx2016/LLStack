#!/bin/bash
set -euo pipefail
# Install PostgreSQL from the PGDG official repo
# Usage: db-install-postgresql.sh --version <16|17|18>
#
# Progress goes to stderr; stdout carries only the final JSON document.

VERSION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done
[[ -z "$VERSION" ]] && { echo '{"ok":false,"error":"missing_args","message":"--version <16|17|18>"}' >&2; exit 1; }

# Validate version — it is interpolated into package names AND into a path that
# gets executed (/usr/pgsql-<v>/bin/postgresql-<v>-setup).
if ! [[ "$VERSION" =~ ^1[6-8]$ ]]; then
    echo '{"ok":false,"error":"invalid_version","message":"Supported: 16, 17, 18"}' >&2; exit 1
fi

MAJOR_VER=$(. /etc/os-release; echo "${VERSION_ID%%.*}")
ARCH=$(uname -m)

echo ">>> Setting up PostgreSQL PGDG repository..." >&2
if ! rpm -q pgdg-redhat-repo &>/dev/null; then
    if ! dnf install -y "https://download.postgresql.org/pub/repos/yum/reporpms/EL-${MAJOR_VER}-${ARCH}/pgdg-redhat-repo-latest.noarch.rpm" >&2 2>&1; then
        echo '{"ok":false,"error":"repo_setup_failed"}' >&2; exit 1
    fi
fi

# Disable the built-in PostgreSQL module (needed on EL8, harmless on EL9+)
dnf -qy module disable postgresql 2>/dev/null || true

echo ">>> Installing PostgreSQL $VERSION..." >&2
if ! dnf install -y "postgresql${VERSION}-server" "postgresql${VERSION}" >&2 2>&1; then
    echo '{"ok":false,"error":"install_failed"}' >&2; exit 1
fi

SETUP_BIN="/usr/pgsql-${VERSION}/bin/postgresql-${VERSION}-setup"
if [[ ! -x "$SETUP_BIN" ]]; then
    echo '{"ok":false,"error":"setup_binary_missing","message":"'"$SETUP_BIN"' not found after install"}' >&2
    exit 1
fi

# initdb is a no-op if the cluster already exists; only a real failure on an empty
# datadir should abort.
echo ">>> Initializing database..." >&2
if ! "$SETUP_BIN" initdb >&2 2>&1; then
    if [[ ! -f "/var/lib/pgsql/${VERSION}/data/PG_VERSION" ]]; then
        echo '{"ok":false,"error":"initdb_failed"}' >&2; exit 1
    fi
    echo "    (cluster already initialized)" >&2
fi

SERVICE="postgresql-${VERSION}"
echo ">>> Starting PostgreSQL..." >&2
if ! systemctl enable --now "$SERVICE" >&2 2>&1; then
    echo '{"ok":false,"error":"start_failed","message":"'"$SERVICE"' did not start"}' >&2; exit 1
fi

INSTALLED_VER=$("/usr/pgsql-${VERSION}/bin/psql" --version 2>/dev/null | grep -oE '[0-9]+' | head -1 || echo "")

echo ">>> PostgreSQL $VERSION installed successfully" >&2
# Report the versioned unit name: the panel's service list and llstack-ctl's
# allowlist need it (plain "postgresql" is not the unit PGDG installs).
printf '{"ok":true,"data":{"engine":"postgresql","requested":"%s","installed":"%s","service":"%s"}}\n' \
    "$VERSION" "${INSTALLED_VER:-unknown}" "$SERVICE"
