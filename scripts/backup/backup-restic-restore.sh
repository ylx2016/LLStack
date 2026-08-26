#!/bin/bash
set -euo pipefail

# Restore a restic snapshot
# Usage: backup-restic-restore.sh --repo <path> --password-file <path> \
#        --snapshot <id> --target <path> [--force]

REPO="" PW_FILE="" SNAPSHOT="" TARGET=""
FORCE=false
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)          REPO="$2"; shift 2 ;;
        --password-file) PW_FILE="$2"; shift 2 ;;
        --snapshot)      SNAPSHOT="$2"; shift 2 ;;
        --target)        TARGET="$2"; shift 2 ;;
        --force)         FORCE=true; shift ;;
        --exclude|--include)
            [[ -n "${2:-}" ]] || { echo '{"ok":false,"error":"empty_exclude_include"}' >&2; exit 1; }
            EXTRA_ARGS+=("$1" "$2"); shift 2 ;;
        *) shift ;;
    esac
done

[[ -z "$REPO" || -z "$PW_FILE" || -z "$SNAPSHOT" || -z "$TARGET" ]] && {
    echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }

# Validate snapshot ID format (hex)
if ! echo "$SNAPSHOT" | grep -qP '^[a-f0-9]{8,}$'; then
    echo '{"ok":false,"error":"invalid_snapshot_id"}' >&2; exit 1
fi

# Validate target path: must be absolute, under an allowed root, and contain no
# '..' (a snapshot restoring over /home/../etc would still be allowed by the
# path prefix check alone).
if [[ ! "$TARGET" =~ ^/(home|opt|var|tmp)/ ]] || [[ "$TARGET" == *".."* ]]; then
    echo '{"ok":false,"error":"invalid_target_path"}' >&2; exit 1
fi

# Refuse to restore over a non-empty target unless --force is given. Restic
# silently overwrites files, and on a production site that means the running
# application's source is replaced underneath it.
if [[ -e "$TARGET" ]]; then
    if [[ -d "$TARGET" ]] && [[ -n "$(ls -A "$TARGET" 2>/dev/null)" ]]; then
        if [[ "$FORCE" != true ]]; then
            echo "{\"ok\":false,\"error\":\"target_not_empty\",\"message\":\"$TARGET is not empty; pass --force to overwrite\"}" >&2
            exit 1
        fi
        echo ">>> --force given: restoring over non-empty $TARGET" >&2
    fi
fi

mkdir -p "$TARGET"

echo ">>> Restoring snapshot $SNAPSHOT to $TARGET..." >&2
restic -r "$REPO" --password-file "$PW_FILE" restore "$SNAPSHOT" --target "$TARGET" "${EXTRA_ARGS[@]}" >&2 2>&1

echo ">>> Restore complete" >&2
echo "{\"ok\":true,\"data\":{\"snapshot\":\"$SNAPSHOT\",\"target\":\"$TARGET\"}}"
