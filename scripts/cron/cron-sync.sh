#!/bin/bash
set -euo pipefail

# Rebuild one user's crontab from the panel database
# Usage: cron-sync.sh --user <system_user>
#
# This script used to `echo '{"ok":true}'` and do nothing, and cron-remove.sh
# delegated to it — so deleting a job in the panel removed the database row and
# left the entry running in the system crontab forever.
#
# Only the block between the two LLSTACK markers is managed; anything the user
# put in their crontab by hand is preserved verbatim.
#
# Progress goes to stderr; stdout carries only the final JSON document, because
# the backend parses the whole of stdout with json.loads().

SYS_USER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) SYS_USER="${2:-}"; shift 2 ;;
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

DB_PATH="${LLSTACK_DB_PATH:-/opt/llstack/data/llstack.db}"
if [[ ! -f "$DB_PATH" ]]; then
    echo '{"ok":false,"error":"database_not_found"}' >&2; exit 1
fi

TMP=$(mktemp /tmp/llstack-crontab.XXXXXXXXXX)
chmod 600 "$TMP"
trap 'rm -f "$TMP" "$TMP.err"' EXIT

# "no crontab for x" is the normal empty case; any other failure must not be
# read as "the user had no entries", or this rewrite would delete hand-written
# crontab lines it never saw.
if ! CURRENT=$(crontab -u "$SYS_USER" -l 2>"$TMP.err"); then
    if grep -qi 'no crontab' "$TMP.err"; then
        CURRENT=""
    else
        echo ">>> crontab -l failed:" >&2; cat "$TMP.err" >&2 || true
        echo '{"ok":false,"error":"crontab_read_failed","message":"refusing to rewrite a crontab that could not be read"}' >&2
        exit 1
    fi
fi

COUNT=$(CRONTAB_IN="$CURRENT" python3 - "$DB_PATH" "$SYS_USER" "$TMP" <<'PYEOF'
import os, re, sqlite3, sys

db, sys_user, out_path = sys.argv[1:4]

BEGIN = "# --- BEGIN LLSTACK MANAGED (rebuilt by cron-sync.sh; do not edit) ---"
END = "# --- END LLSTACK MANAGED ---"

SPECIAL = {"@reboot", "@yearly", "@annually", "@monthly", "@weekly",
           "@daily", "@midnight", "@hourly"}


def valid(expression, command):
    # A newline in either field would inject an extra crontab line; a % is
    # crontab's stdin separator and silently truncates the command.
    for field in (expression, command):
        if not field or re.search(r'[\x00-\x1f\x7f]', field):
            return False
    if "%" in command:
        return False
    parts = expression.split()
    if parts[0] in SPECIAL:
        return len(parts) == 1
    return len(parts) == 5


conn = sqlite3.connect(db)
try:
    rows = conn.execute(
        "SELECT c.expression, c.command FROM cron_jobs c "
        "JOIN users u ON c.user_id = u.id "
        "WHERE u.system_user = ? AND COALESCE(c.enabled, 1) = 1 "
        "ORDER BY c.id", (sys_user,)).fetchall()
except sqlite3.Error as exc:
    print("cron_jobs unreadable: %s" % exc, file=sys.stderr)
    sys.exit(1)

managed = []
for expression, command in rows:
    expression = (expression or "").strip()
    command = (command or "").strip()
    if not valid(expression, command):
        print("  skipping invalid job: %r %r" % (expression, command), file=sys.stderr)
        continue
    managed.append("%s %s" % (expression, command))

# Strip any previous managed block, keep the user's own lines
existing = os.environ.get("CRONTAB_IN", "")
kept, inside = [], False
for line in existing.splitlines():
    if line.strip() == BEGIN:
        inside = True
        continue
    if line.strip() == END:
        inside = False
        continue
    if not inside:
        kept.append(line)

while kept and not kept[-1].strip():
    kept.pop()

out = list(kept)
if managed:
    if out:
        out.append("")
    out.append(BEGIN)
    out.extend(managed)
    out.append(END)

with open(out_path, "w") as f:
    if out:
        f.write("\n".join(out) + "\n")

print(len(managed))
PYEOF
) || { echo '{"ok":false,"error":"sync_failed","message":"could not build crontab from database"}' >&2; exit 1; }

if ! crontab -u "$SYS_USER" "$TMP" >&2; then
    echo '{"ok":false,"error":"crontab_install_failed"}' >&2; exit 1
fi

echo ">>> crontab for $SYS_USER rebuilt: $COUNT managed job(s)" >&2
echo "{\"ok\":true,\"data\":{\"user\":\"$SYS_USER\",\"jobs\":$COUNT}}"
