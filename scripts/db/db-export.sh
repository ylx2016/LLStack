#!/bin/bash
set -euo pipefail

# Export database dump with optimized flags
# Usage: db-export.sh --engine <engine> --name <db_name> [--schema-only]

ENGINE="" NAME="" SCHEMA_ONLY=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine)      ENGINE="$2"; shift 2 ;;
        --name)        NAME="$2"; shift 2 ;;
        --schema-only) SCHEMA_ONLY=true; shift ;;
        *) echo '{"ok":false,"error":"unknown_arg: '"$1"'"}' >&2; exit 1 ;;
    esac
done

[[ -z "$ENGINE" || -z "$NAME" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }

# Validate DB name
if ! echo "$NAME" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,63}$'; then
    echo '{"ok":false,"error":"invalid_db_name"}' >&2; exit 1
fi

umask 0077
# GNU mktemp requires the template to end in X. Create with the suffix as a
# separate step (same pattern as backup-restic-snapshot.sh after the earlier
# audit fix).
OUTPUT=$(mktemp); mv "$OUTPUT" "${OUTPUT}.sql.gz"; OUTPUT="${OUTPUT}.sql.gz"

case "$ENGINE" in
    mariadb|mysql)
        DUMP_ARGS=(
            --single-transaction
            --quick
            --extended-insert
            --routines
            --triggers
            --events
        )
        if [[ "$SCHEMA_ONLY" == true ]]; then
            DUMP_ARGS+=(--no-data)
        fi
        if ! mysqldump "${DUMP_ARGS[@]}" "$NAME" 2>/dev/null | gzip > "$OUTPUT"; then
            rm -f "$OUTPUT"; echo '{"ok":false,"error":"dump_failed","message":"Database dump failed"}' >&2; exit 1
        fi
        ;;
    postgresql)
        PG_ARGS=()
        if [[ "$SCHEMA_ONLY" == true ]]; then
            PG_ARGS+=(--schema-only)
        fi
        if ! sudo -u postgres pg_dump "${PG_ARGS[@]}" "$NAME" 2>/dev/null | gzip > "$OUTPUT"; then
            rm -f "$OUTPUT"; echo '{"ok":false,"error":"dump_failed","message":"Database dump failed"}' >&2; exit 1
        fi
        ;;
    *) rm -f "$OUTPUT"; echo '{"ok":false,"error":"unsupported_engine"}' >&2; exit 1 ;;
esac

chmod 600 "$OUTPUT"
SIZE=$(stat -c%s "$OUTPUT" 2>/dev/null || echo 0)
# Use Python for JSON serialization so $OUTPUT (which lives under /tmp) cannot
# break the contract the backend parses the whole of stdout for.
python3 - "$OUTPUT" "$SIZE" "$SCHEMA_ONLY" <<'PYEOF'
import json, sys
output, size, schema_only = sys.argv[1], int(sys.argv[2]), sys.argv[3] == "true"
print(json.dumps({
    "ok": True,
    "data": {"path": output, "size": size, "schema_only": schema_only},
}, separators=(",", ":")))
PYEOF
