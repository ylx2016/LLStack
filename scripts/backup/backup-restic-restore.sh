#!/bin/bash
set -euo pipefail

# Restore a restic snapshot
# Usage: backup-restic-restore.sh --repo <path> --password-file <path> --snapshot <id> --target <path>

REPO="" PW_FILE="" SNAPSHOT="" TARGET=""
EXTRA_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)          REPO="$2"; shift 2 ;;
        --password-file) PW_FILE="$2"; shift 2 ;;
        --snapshot)      SNAPSHOT="$2"; shift 2 ;;
        --target)        TARGET="$2"; shift 2 ;;
        --exclude|--include) EXTRA_ARGS+=("$1" "$2"); shift 2 ;;
        *) shift ;;
    esac
done

[[ -z "$REPO" || -z "$PW_FILE" || -z "$SNAPSHOT" || -z "$TARGET" ]] && {
    echo '{"ok":false,"error":"missing_args"}' >&2; exit 1
}

# Validate snapshot ID format (hex)
if ! echo "$SNAPSHOT" | grep -qP '^[a-f0-9]{8,}$'; then
    echo '{"ok":false,"error":"invalid_snapshot_id"}' >&2; exit 1
fi

# Validate target path
if [[ ! "$TARGET" =~ ^/(home|opt|var|tmp)/ ]]; then
    echo '{"ok":false,"error":"invalid_target_path"}' >&2; exit 1
fi

mkdir -p "$TARGET"

echo ">>> Restoring snapshot $SNAPSHOT to $TARGET..." >&2
restic -r "$REPO" --password-file "$PW_FILE" restore "$SNAPSHOT" --target "$TARGET" "${EXTRA_ARGS[@]}" >&2 2>&1

echo ">>> Restore complete" >&2
echo "{\"ok\":true,\"data\":{\"snapshot\":\"$SNAPSHOT\",\"target\":\"$TARGET\"}}"
