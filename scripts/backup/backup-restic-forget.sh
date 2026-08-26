#!/bin/bash
set -euo pipefail

# Apply retention policy and prune old snapshots
# Usage: backup-restic-forget.sh --repo <path> --password-file <path> \
#        [--keep-last <n>] [--keep-daily <n>] [--keep-weekly <n>] [--keep-monthly <n>]

REPO="" PW_FILE="" KEEP_LAST=7 KEEP_DAILY=30 KEEP_WEEKLY=4 KEEP_MONTHLY=6
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)          REPO="$2"; shift 2 ;;
        --password-file) PW_FILE="$2"; shift 2 ;;
        --keep-last)     KEEP_LAST="$2"; shift 2 ;;
        --keep-daily)    KEEP_DAILY="$2"; shift 2 ;;
        --keep-weekly)   KEEP_WEEKLY="$2"; shift 2 ;;
        --keep-monthly)  KEEP_MONTHLY="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$REPO" || -z "$PW_FILE" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }

echo ">>> Applying retention policy: last=$KEEP_LAST daily=$KEEP_DAILY weekly=$KEEP_WEEKLY monthly=$KEEP_MONTHLY" >&2

restic -r "$REPO" --password-file "$PW_FILE" forget \
    --keep-last "$KEEP_LAST" \
    --keep-daily "$KEEP_DAILY" \
    --keep-weekly "$KEEP_WEEKLY" \
    --keep-monthly "$KEEP_MONTHLY" \
    --prune >&2 2>&1

echo '{"ok":true,"data":{"pruned":true}}'
