#!/bin/bash
set -euo pipefail

# Create a restic snapshot (incremental backup)
# Usage: backup-restic-snapshot.sh --repo <path> --password-file <path> \
#        --paths <path1,path2> [--tag <tag>] [--db-name <name>] [--db-engine <mariadb|postgresql>]

REPO="" PW_FILE="" PATHS="" TAG="" DB_NAME="" DB_ENGINE=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --repo)          REPO="$2"; shift 2 ;;
        --password-file) PW_FILE="$2"; shift 2 ;;
        --paths)         PATHS="$2"; shift 2 ;;
        --tag)           TAG="$2"; shift 2 ;;
        --db-name)       DB_NAME="$2"; shift 2 ;;
        --db-engine)     DB_ENGINE="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$REPO" || -z "$PW_FILE" || -z "$PATHS" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }

# Validate paths
IFS=',' read -ra PATH_ARRAY <<< "$PATHS"
BACKUP_PATHS=()
for p in "${PATH_ARRAY[@]}"; do
    # Trim leading/trailing whitespace without xargs (which would re-parse quotes/backslashes)
    p="${p#"${p%%[![:space:]]*}"}"
    p="${p%"${p##*[![:space:]]}"}"
    [[ -d "$p" || -f "$p" ]] && BACKUP_PATHS+=("$p")
done

[[ ${#BACKUP_PATHS[@]} -eq 0 ]] && { echo '{"ok":false,"error":"no_valid_paths"}' >&2; exit 1; }

# Database dump (if requested)
DB_DUMP=""
if [[ -n "$DB_NAME" && -n "$DB_ENGINE" ]]; then
    # Validate DB name
    if ! echo "$DB_NAME" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,63}$'; then
        echo '{"ok":false,"error":"invalid_db_name"}' >&2; exit 1
    fi

    # GNU mktemp requires the template to end in X (not .sql.gz), so create
    # the temp file first and then add the suffix. mktemp -t would also work
    # but its filename depends on $TMPDIR and is harder to reason about.
    DB_DUMP=$(mktemp); mv "$DB_DUMP" "${DB_DUMP}.sql.gz"; DB_DUMP="${DB_DUMP}.sql.gz"
    trap "rm -f '$DB_DUMP'" EXIT

    echo ">>> Dumping database: $DB_NAME ($DB_ENGINE)..." >&2
    case "$DB_ENGINE" in
        mariadb|mysql)
            if ! mysqldump --single-transaction --quick "$DB_NAME" 2>/dev/null | gzip > "$DB_DUMP"; then
                echo "  WARNING: database dump failed for $DB_NAME (files will still be snapshotted)" >&2
                DB_DUMP=""
            fi
            ;;
        postgresql)
            if ! sudo -u postgres pg_dump "$DB_NAME" 2>/dev/null | gzip > "$DB_DUMP"; then
                echo "  WARNING: database dump failed for $DB_NAME (files will still be snapshotted)" >&2
                DB_DUMP=""
            fi
            ;;
        *)
            echo '{"ok":false,"error":"unsupported_db_engine"}' >&2; exit 1
            ;;
    esac

    if [[ -n "$DB_DUMP" && -s "$DB_DUMP" ]]; then
        BACKUP_PATHS+=("$DB_DUMP")
        echo "  Database dump: $(du -h "$DB_DUMP" | awk '{print $1}')" >&2
    fi
fi

# Build restic command
RESTIC_ARGS=(-r "$REPO" --password-file "$PW_FILE" backup)
[[ -n "$TAG" ]] && RESTIC_ARGS+=(--tag "$TAG")

echo ">>> Creating restic snapshot..." >&2
echo "  Paths: ${BACKUP_PATHS[*]}" >&2

OUTPUT=$(restic "${RESTIC_ARGS[@]}" "${BACKUP_PATHS[@]}" --json 2>&1 | tail -1)

# Parse snapshot ID from JSON output
SNAPSHOT_ID=$(echo "$OUTPUT" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    print(d.get('snapshot_id', d.get('id', '')))
except:
    print('')
" 2>/dev/null || echo "")

if [[ -n "$SNAPSHOT_ID" ]]; then
    echo ">>> Snapshot created: $SNAPSHOT_ID" >&2
    echo "{\"ok\":true,\"data\":{\"snapshot_id\":\"$SNAPSHOT_ID\",\"tag\":\"$TAG\"}}"
else
    # Try without --json for older restic versions
    SNAPSHOT_ID=$(echo "$OUTPUT" | grep -oP 'snapshot [a-f0-9]+' | awk '{print $2}' || echo "")
    echo "{\"ok\":true,\"data\":{\"snapshot_id\":\"${SNAPSHOT_ID:-unknown}\",\"tag\":\"$TAG\"}}"
fi
