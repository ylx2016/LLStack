#!/bin/bash
set -euo pipefail
# Install Typecho into a site's document root
# Usage: app-typecho.sh --domain <domain> --doc-root <path> [--php <phpXX>]
#
# Progress goes to stderr; stdout carries only the final JSON document.
#
# Layout detection note: the Typecho release zip is at root level (build/ does
# not exist in current releases), but earlier versions of this script tried to
# match a `build/` subdir after a single-wrapper strip — which never matched,
# because real archives are either root-level (no strip needed) or single-wrapper
# (strip once). The detection chain now runs in the order: (1) root-level
# index.php, (2) strip one wrapper, (3) try build/ inside wrapper, (4) fail.
# This makes the heuristic also accept wrapper/build/ if a future release ships it.

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
if ! [[ "$PHP_VERSION" =~ ^php[0-9]+$ ]]; then
    echo '{"ok":false,"error":"invalid_php_version"}' >&2; exit 1
fi

# Work in a private directory: writing to a fixed /tmp path as root lets any local
# user pre-create a symlink there and redirect the download/extraction.
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Get the latest release's tag and pin the download to it. The previous
# `releases/latest/download/typecho.zip` URL follows redirects to whatever
# GitHub considers "latest" at fetch time, so a different tarball could land on
# a future run even when nothing in the panel changed.
echo ">>> Resolving latest Typecho release tag..." >&2
TAG=$(curl -fsSL --max-time 15 -o /dev/null -w '%{url_effective}' \
        https://github.com/typecho/typecho/releases/latest 2>/dev/null \
    | sed -E 's@.*/tag/@@')
if [[ -z "$TAG" || ! "$TAG" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo '{"ok":false,"error":"tag_resolution_failed"}' >&2; exit 1
fi
URL="https://github.com/typecho/typecho/releases/download/${TAG}/typecho.zip"

echo ">>> Downloading Typecho $TAG..." >&2
if ! curl -fsSL --retry 3 --max-time 120 "$URL" -o "$WORK/typecho.zip"; then
    echo '{"ok":false,"error":"download_failed","message":"'"$URL"'"}' >&2; exit 1
fi

echo ">>> Extracting..." >&2
if ! unzip -qo "$WORK/typecho.zip" -d "$WORK/extract" >&2 2>&1; then
    echo '{"ok":false,"error":"extract_failed"}' >&2; exit 1
fi

shopt -s dotglob nullglob
SRC="$WORK/extract"

# Layout detection. Real releases are either root-level (no wrapper, index.php
# at the top of the extract dir) or single-wrapper (one top-level dir, with
# index.php inside). Some past releases also had a wrapper with a build/ dir
# inside. The order below is: try root-level first, then strip one wrapper,
# then look for build/ inside the wrapper.
if [[ -f "$SRC/index.php" ]]; then
    :  # (1) already root-level
elif entries=("$SRC"/*) && [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
    SRC="${entries[0]}"
    [[ -f "$SRC/index.php" ]] || { [[ -d "$SRC/build" ]] && SRC="$SRC/build"; }
fi
shopt -u dotglob nullglob

if [[ ! -f "$SRC/index.php" ]]; then
    echo '{"ok":false,"error":"unexpected_archive_layout","message":"index.php not found in the extracted archive"}' >&2
    exit 1
fi
cp -a "$SRC/." "$DOC_ROOT/"

SITE_USER=$(stat -c '%U' "$DOC_ROOT" 2>/dev/null || echo root)
chown -R "$SITE_USER:$SITE_USER" "$DOC_ROOT" 2>/dev/null || true

echo ">>> Typecho installed" >&2
# Use Python for JSON serialization so user-supplied values containing " or \
# cannot break the contract the backend parses the whole of stdout for.
python3 - "$DOMAIN" "$DOC_ROOT" <<'PYEOF'
import json, sys
domain, doc_root = sys.argv[1], sys.argv[2]
print(json.dumps({
    "ok": True,
    "data": {
        "app": "typecho",
        "name": "Typecho",
        "domain": domain,
        "doc_root": doc_root,
    },
}, separators=(",", ":")))
PYEOF
