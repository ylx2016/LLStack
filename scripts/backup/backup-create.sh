#!/bin/bash
set -euo pipefail

# Create site backup (files + database)
# Usage: backup-create.sh --site <domain> --type <full|files|db> --output <path>

SITE=""
TYPE="full"
OUTPUT=""
DB_NAME_OVERRIDE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --site)    SITE="$2"; shift 2 ;;
        --type)    TYPE="$2"; shift 2 ;;
        --output)  OUTPUT="$2"; shift 2 ;;
        --db-name) DB_NAME_OVERRIDE="$2"; shift 2 ;;
        *) echo '{"ok": false, "error": "unknown_arg"}' >&2; exit 1 ;;
    esac
done

if [[ -z "$SITE" || -z "$OUTPUT" ]]; then
    echo '{"ok": false, "error": "missing_args"}' >&2
    exit 1
fi

# Prevent concurrent backups for same site
LOCK_FILE="/var/lock/llstack-backup-$(echo "$SITE" | tr '/' '_').lock"
exec 100>"$LOCK_FILE"
if ! flock -n 100; then
    echo '{"ok": false, "error": "backup_already_running"}' >&2
    exit 1
fi

# Find doc_root
DOC_ROOT=""
VHCONF="/usr/local/lsws/conf/vhosts/$SITE/vhconf.conf"
if [[ -f "$VHCONF" ]]; then
    DOC_ROOT=$(grep 'docRoot' "$VHCONF" | awk '{print $2}' | head -1)
fi

# Fallback: search home directories
if [[ -z "$DOC_ROOT" || ! -d "$DOC_ROOT" ]]; then
    for d in /home/*/public_html/"$SITE"; do
        if [[ -d "$d" ]]; then
            DOC_ROOT="$d"
            break
        fi
    done
fi

# Normalize OUTPUT to an absolute path BEFORE cd — a relative --output would
# otherwise be resolved against $TMPDIR and deleted on exit -> data loss.
if command -v realpath &>/dev/null; then
    OUTPUT=$(realpath "$OUTPUT")
else
    case "$OUTPUT" in
        /*) ;;
        *) OUTPUT="$PWD/$OUTPUT" ;;
    esac
fi
mkdir -p "$(dirname "$OUTPUT")"
TMPDIR=$(mktemp -d -t llstack-backup.XXXXXXXXXX)
[[ -L "$TMPDIR" ]] && { echo '{"ok":false,"error":"tmpdir_symlink"}' >&2; exit 1; }
trap 'rm -rf "$TMPDIR"' EXIT

HAS_CONTENT=false

# Backup files
if [[ "$TYPE" == "full" || "$TYPE" == "files" ]]; then
    if [[ -d "$DOC_ROOT" ]]; then
        tar czf "$TMPDIR/files.tar.gz" -C "$(dirname "$DOC_ROOT")" "$(basename "$DOC_ROOT")" 2>/dev/null
        HAS_CONTENT=true
    else
        echo "    WARNING: doc root not found ($DOC_ROOT) — files skipped" >&2
    fi
fi

# Backup database (prefer explicit --db-name, else try common WP naming patterns)
if [[ "$TYPE" == "full" || "$TYPE" == "db" ]]; then
    DB_CANDIDATES=()
    if [[ -n "$DB_NAME_OVERRIDE" ]]; then
        DB_CANDIDATES+=("$DB_NAME_OVERRIDE")
    else
        SITE_SLUG=$(echo "$SITE" | tr '.' '_' | tr '-' '_')
        # WP install_quick uses wp_<slug[:20]>; staging uses <slug[:32]>_stg
        DB_CANDIDATES+=("wp_${SITE_SLUG:0:20}" "${SITE_SLUG:0:32}_stg" "$SITE_SLUG")
    fi
    for DB_NAME in "${DB_CANDIDATES[@]}"; do
        if ! echo "$DB_NAME" | grep -qP '^[a-zA-Z_][a-zA-Z0-9_]{0,63}$'; then
            continue
        fi
        if mysql -e "USE \`$DB_NAME\`" 2>/dev/null; then
            if ! mysqldump "$DB_NAME" 2>/dev/null | gzip > "$TMPDIR/database.sql.gz"; then
                # Dump failed — don't silently claim a DB backup that isn't there.
                echo "    WARNING: database dump failed for $DB_NAME (skipping DB, files still backed up)" >&2
                rm -f "$TMPDIR/database.sql.gz"
            else
                echo "    Database backed up: $DB_NAME" >&2
                # Record the actual DB name so restore doesn't have to guess
                echo "{\"db_name\": \"$DB_NAME\"}" > "$TMPDIR/metadata.json"
                HAS_CONTENT=true
                break
            fi
        fi
    done
fi

# Create final archive
if [[ "$HAS_CONTENT" != true ]]; then
    echo '{"ok":false,"error":"nothing_to_backup","message":"No files or database found to back up"}' >&2
    exit 1
fi
cd "$TMPDIR"
tar czf "$OUTPUT" ./* 2>/dev/null

SIZE=$(stat -c%s "$OUTPUT" 2>/dev/null || echo 0)

# Use Python for JSON serialization. $OUTPUT is a file path the operator
# provided via --output and could contain " or \. $TYPE is validated
# (full|files|db) but the doc tree is built once via json.dumps either way.
python3 - "$OUTPUT" "$SIZE" "$TYPE" <<'PYEOF'
import json, sys
output, size, type_ = sys.argv[1], int(sys.argv[2]), sys.argv[3]
print(json.dumps({
    "ok": True,
    "data": {"path": output, "size": size, "type": type_},
}, separators=(",", ":")))
PYEOF
