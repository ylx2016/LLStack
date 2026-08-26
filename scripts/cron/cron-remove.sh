#!/bin/bash
set -euo pipefail

# Remove one cron job from a user's managed crontab block
# Usage: cron-remove.sh --user <system_user> [--id <job_id>] [--expression <e> --command <c>]
#
# This script used to `echo '{"ok":true}'` without touching the crontab, so a job
# deleted in the panel kept firing until the machine was rebuilt.
#
# Both call orders are handled: if the database row is already gone the crontab is
# rebuilt from the database (cron-sync.sh), and if the row is still there the
# matching line is removed directly.
#
# Progress goes to stderr; stdout carries only the final JSON document, because
# the backend parses the whole of stdout with json.loads().

SYS_USER="" ID="" EXPRESSION="" COMMAND=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)       SYS_USER="${2:-}"; shift 2 ;;
        --id)         ID="${2:-}"; shift 2 ;;
        --expression) EXPRESSION="${2:-}"; shift 2 ;;
        --command)    COMMAND="${2:-}"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$SYS_USER" ]] && { echo '{"ok":false,"error":"missing_args","message":"--user is required"}' >&2; exit 1; }

if ! [[ "$SYS_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo '{"ok":false,"error":"invalid_user"}' >&2; exit 1
fi
if ! id "$SYS_USER" &>/dev/null; then
    echo '{"ok":false,"error":"unknown_user","message":"no such system user"}' >&2; exit 1
fi
if [[ -n "$ID" ]] && ! [[ "$ID" =~ ^[0-9]+$ ]]; then
    echo '{"ok":false,"error":"invalid_id"}' >&2; exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DB_PATH="${LLSTACK_DB_PATH:-/opt/llstack/data/llstack.db}"

# When only an id is given, look the entry up while the row still exists. If the
# backend already deleted it, a full rebuild from the database is what removes it.
if [[ -z "$EXPRESSION" || -z "$COMMAND" ]]; then
    if [[ -n "$ID" && -f "$DB_PATH" ]]; then
        ROW=$(python3 - "$DB_PATH" "$ID" "$SYS_USER" <<'PYEOF'
import sqlite3, sys
db, job_id, sys_user = sys.argv[1:4]
conn = sqlite3.connect(db)
try:
    row = conn.execute(
        "SELECT c.expression, c.command FROM cron_jobs c "
        "JOIN users u ON c.user_id = u.id "
        "WHERE c.id = ? AND u.system_user = ?", (job_id, sys_user)).fetchone()
except sqlite3.Error:
    row = None
if row:
    print("%s\x1f%s" % (row[0] or "", row[1] or ""))
PYEOF
) || ROW=""
        if [[ -n "$ROW" ]]; then
            EXPRESSION="${ROW%%$'\x1f'*}"
            COMMAND="${ROW#*$'\x1f'}"
        fi
    fi
fi

if [[ -z "$EXPRESSION" || -z "$COMMAND" ]]; then
    echo ">>> No live database row for id='$ID' — rebuilding $SYS_USER's crontab from the database" >&2
    exec "$SCRIPT_DIR/cron-sync.sh" --user "$SYS_USER"
fi

TMP=$(mktemp /tmp/llstack-crontab.XXXXXXXXXX)
chmod 600 "$TMP"
trap 'rm -f "$TMP" "$TMP.err"' EXIT

if ! CURRENT=$(crontab -u "$SYS_USER" -l 2>"$TMP.err"); then
    if grep -qi 'no crontab' "$TMP.err"; then
        echo ">>> $SYS_USER has no crontab; nothing to remove" >&2
        echo "{\"ok\":true,\"data\":{\"user\":\"$SYS_USER\",\"removed\":0}}"
        exit 0
    fi
    echo ">>> crontab -l failed:" >&2; cat "$TMP.err" >&2 || true
    echo '{"ok":false,"error":"crontab_read_failed","message":"refusing to rewrite a crontab that could not be read"}' >&2
    exit 1
fi

REMOVED=$(CRONTAB_IN="$CURRENT" python3 - "$EXPRESSION" "$COMMAND" "$TMP" <<'PYEOF'
import os, sys

expression, command, out_path = sys.argv[1:4]

BEGIN = "# --- BEGIN LLSTACK MANAGED (rebuilt by cron-sync.sh; do not edit) ---"
END = "# --- END LLSTACK MANAGED ---"

target = "%s %s" % (expression.strip(), command.strip())
target_norm = " ".join(target.split())

before, managed, after = [], [], []
state = "before"
for line in os.environ.get("CRONTAB_IN", "").splitlines():
    stripped = line.strip()
    if stripped == BEGIN:
        state = "inside"
        continue
    if stripped == END:
        state = "after"
        continue
    {"before": before, "inside": managed, "after": after}[state].append(line)

kept, removed = [], 0
for line in managed:
    if " ".join(line.split()) == target_norm:
        removed += 1
        continue
    kept.append(line)


# Entries added before this managed block existed still live outside it, and
# their position relative to the block is preserved.
def strip_target(lines):
    global removed
    out = []
    for line in lines:
        if " ".join(line.split()) == target_norm:
            removed += 1
            continue
        out.append(line)
    return out


before = strip_target(before)
after = strip_target(after)

out = list(before)
while out and not out[-1].strip():
    out.pop()
if kept:
    if out:
        out.append("")
    out.append(BEGIN)
    out.extend(kept)
    out.append(END)
out.extend(after)
while out and not out[-1].strip():
    out.pop()

with open(out_path, "w") as f:
    if out:
        f.write("\n".join(out) + "\n")

print(removed)
PYEOF
) || { echo '{"ok":false,"error":"crontab_build_failed"}' >&2; exit 1; }

if ! crontab -u "$SYS_USER" "$TMP" >&2; then
    echo '{"ok":false,"error":"crontab_install_failed"}' >&2; exit 1
fi

echo ">>> $SYS_USER: removed=$REMOVED" >&2
echo "{\"ok\":true,\"data\":{\"user\":\"$SYS_USER\",\"removed\":$REMOVED}}"
