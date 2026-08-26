#!/bin/bash
set -euo pipefail

# Get restic repository statistics
# Usage: backup-restic-stats.sh --repo <path> --password-file <path>

REPO="" PW_FILE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)          REPO="$2"; shift 2 ;;
        --password-file) PW_FILE="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$REPO" || -z "$PW_FILE" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }

if STATS=$(restic -r "$REPO" --password-file "$PW_FILE" stats --json 2>&1); then
    echo "{\"ok\":true,\"data\":$STATS}"
else
    echo '{"ok":false,"error":"restic_failed","message":"'"$STATS"'"}' >&2; exit 1
fi
