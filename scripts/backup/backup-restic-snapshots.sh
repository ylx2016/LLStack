#!/bin/bash
set -euo pipefail

# List restic snapshots
# Usage: backup-restic-snapshots.sh --repo <path> --password-file <path> [--tag <tag>]

REPO="" PW_FILE="" TAG=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)          REPO="$2"; shift 2 ;;
        --password-file) PW_FILE="$2"; shift 2 ;;
        --tag)           TAG="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$REPO" || -z "$PW_FILE" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }

ARGS=(-r "$REPO" --password-file "$PW_FILE" snapshots --json)
[[ -n "$TAG" ]] && ARGS+=(--tag "$TAG")

# Distinguish "no snapshots" from "restic failed" so we don't report a false success.
if SNAPSHOTS=$(restic "${ARGS[@]}" 2>&1); then
    echo "{\"ok\":true,\"data\":$SNAPSHOTS}"
else
    echo '{"ok":false,"error":"restic_failed","message":"'"$SNAPSHOTS"'"}' >&2; exit 1
fi
