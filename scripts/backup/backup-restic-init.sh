#!/bin/bash
set -euo pipefail

# Initialize a restic repository
# Usage: backup-restic-init.sh --repo <path_or_s3_url> --password-file <path>

REPO="" PW_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)          REPO="$2"; shift 2 ;;
        --password-file) PW_FILE="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$REPO" || -z "$PW_FILE" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }
[[ ! -f "$PW_FILE" ]] && { echo '{"ok":false,"error":"password_file_not_found"}' >&2; exit 1; }

# Check restic is installed
if ! command -v restic &>/dev/null; then
    echo '{"ok":false,"error":"restic_not_installed","message":"Run: dnf install -y restic"}' >&2
    exit 1
fi

# Init repo (skip if already initialized)
if restic -r "$REPO" --password-file "$PW_FILE" snapshots &>/dev/null; then
    echo '{"ok":true,"data":{"status":"already_initialized"}}'
    exit 0
fi

restic init -r "$REPO" --password-file "$PW_FILE" >&2 2>&1

echo '{"ok":true,"data":{"status":"initialized","repo":"'"$REPO"'"}}'
