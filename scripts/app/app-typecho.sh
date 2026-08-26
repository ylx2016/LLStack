#!/bin/bash
set -euo pipefail
# Install Typecho into a site's document root
# Usage: app-typecho.sh --domain <domain> --doc-root <path> [--php <phpXX>]
#
# Progress goes to stderr; stdout carries only the final JSON document.

DOMAIN="" DOC_ROOT="" PHP_VERSION="php83"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)   DOMAIN="$2"; shift 2 ;;
        --doc-root) DOC_ROOT="$2"; shift 2 ;;
        --php)      PHP_VERSION="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done
[[ -z "$DOMAIN" || -z "$DOC_ROOT" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }
[[ ! -d "$DOC_ROOT" ]] && { echo '{"ok":false,"error":"doc_root_not_found"}' >&2; exit 1; }

# Work in a private directory: writing to a fixed /tmp path as root lets any local
# user pre-create a symlink there and redirect the download/extraction.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo ">>> Downloading Typecho..." >&2
if ! curl -fsSL --retry 3 --max-time 120 \
        "https://github.com/typecho/typecho/releases/latest/download/typecho.zip" \
        -o "$WORK/typecho.zip"; then
    echo '{"ok":false,"error":"download_failed"}' >&2; exit 1
fi

echo ">>> Extracting..." >&2
if ! unzip -qo "$WORK/typecho.zip" -d "$WORK/extract" >&2 2>&1; then
    echo '{"ok":false,"error":"extract_failed"}' >&2; exit 1
fi

# Release archives are sometimes root-level and sometimes wrapped in one directory
# (and the manifest's extract_dir has been wrong before). Detect it instead of
# guessing: strip a single wrapper only when that's the actual layout.
shopt -s dotglob nullglob
SRC="$WORK/extract"
if [[ ! -f "$SRC/index.php" ]]; then
    entries=("$SRC"/*)
    if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
        SRC="${entries[0]}"
    elif [[ -d "$SRC/build" ]]; then
        SRC="$SRC/build"
    fi
fi
if [[ ! -f "$SRC/index.php" ]]; then
    echo '{"ok":false,"error":"unexpected_archive_layout","message":"index.php not found in the extracted archive"}' >&2
    exit 1
fi
cp -a "$SRC/." "$DOC_ROOT/"
shopt -u dotglob nullglob

SITE_USER=$(stat -c '%U' "$DOC_ROOT" 2>/dev/null || echo root)
chown -R "$SITE_USER:$SITE_USER" "$DOC_ROOT"

echo ">>> Typecho installed" >&2
printf '{"ok":true,"data":{"app":"typecho","domain":"%s","doc_root":"%s"}}\n' "$DOMAIN" "$DOC_ROOT"
