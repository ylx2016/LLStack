#!/bin/bash
set -euo pipefail

# Install Adminer (PHP database admin UI) into the panel's web dir.
# The panel's backend generates a one-time SSO login URL and includes
# adminer.php from this path when the operator opens the DB page.
# Without this file, every DB page shows adminer_not_installed.
#
# Idempotent: skips if already installed, --force to reinstall.
#
# Progress goes to stderr; stdout carries only the final JSON document.

ADMINER_DIR="/opt/llstack/web/adminer"
ADMINER_FILE="$ADMINER_DIR/index.php"
FORCE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --force) FORCE=true; shift ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

if [[ -f "$ADMINER_FILE" && "$FORCE" != true ]]; then
    echo "{\"ok\":true,\"data\":{\"path\":\"$ADMINER_FILE\",\"already_installed\":true}}"
    exit 0
fi

# /opt/llstack must exist (this script runs as part of the install, or any
# time after). Don't auto-create the parent — that means the panel
# directory layout is wrong.
if [[ ! -d "/opt/llstack" ]]; then
    echo '{"ok":false,"error":"llstack_dir_missing","message":"run install.sh first"}' >&2
    exit 1
fi

mkdir -p "$ADMINER_DIR"

# Try the official stable release first (adminer.org/latest-mysql.php is
# the "current stable" link), then the GitHub release as a fallback.
# Either way we tag with the file's SHA so the operator can verify what
# they got.
URLS=(
    "https://www.adminer.org/latest-mysql.php"
    "https://github.com/vrana/adminer/releases/latest/download/adminer-mysql.php"
)

echo ">>> Downloading Adminer to $ADMINER_FILE..." >&2
TMP=$(mktemp); mv "$TMP" "${TMP}.php"; TMP="${TMP}.php"
trap 'rm -f "$TMP"' EXIT

DOWNLOADED=false
for url in "${URLS[@]}"; do
    if curl -fsSL --max-time 60 "$url" -o "$TMP" 2>/dev/null; then
        # Sanity: adminer is PHP and starts with <?php
        if head -c 5 "$TMP" | grep -q '<?php'; then
            DOWNLOADED=true
            echo "    fetched from $url" >&2
            break
        fi
    fi
done

if [[ "$DOWNLOADED" != true ]]; then
    echo '{"ok":false,"error":"download_failed","message":"could not download adminer.php from any mirror"}' >&2
    exit 1
fi

# Install. adminer.php contains all of adminer in one file; it just needs
# to be reachable as index.php so the panel's /adminer/ URL serves it.
mv "$TMP" "$ADMINER_FILE"
chmod 644 "$ADMINER_FILE"

SHA=$(sha256sum "$ADMINER_FILE" | awk '{print $1}')

echo "{\"ok\":true,\"data\":{\"path\":\"$ADMINER_FILE\",\"sha256\":\"$SHA\"}}"
