#!/bin/bash
set -euo pipefail

# Add one cron job to a user's managed crontab block
# Usage: cron-add.sh --user <system_user> --expression <cron expr> --command <cmd>
#
# The entry is written inside the block cron-sync.sh manages, so a later sync
# from the database keeps it instead of dropping an entry it does not recognise.
#
# Progress goes to stderr; stdout carries only the final JSON document, because
# the backend parses the whole of stdout with json.loads().

SYS_USER="" EXPRESSION="" COMMAND=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user)       SYS_USER="${2:-}"; shift 2 ;;
        --expression) EXPRESSION="${2:-}"; shift 2 ;;
        --command)    COMMAND="${2:-}"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$SYS_USER" || -z "$EXPRESSION" || -z "$COMMAND" ]] && {
    echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }

if ! [[ "$SYS_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo '{"ok":false,"error":"invalid_user"}' >&2; exit 1
fi
if ! id "$SYS_USER" &>/dev/null; then
    echo '{"ok":false,"error":"unknown_user","message":"no such system user"}' >&2; exit 1
fi

# Reject control characters (incl. newline, which grep is line-oriented and misses)
# to prevent crontab injection.
if [[ "$EXPRESSION$COMMAND" =~ $'\n' ]] || \
   printf '%s' "$EXPRESSION$COMMAND" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    echo '{"ok":false,"error":"invalid_chars"}' >&2; exit 1
fi

# cron reads everything after an unescaped % as stdin for the command, so a %
# silently truncates what actually runs.
if [[ "$COMMAND" == *%* ]]; then
    echo '{"ok":false,"error":"invalid_chars","message":"% is not allowed in a cron command"}' >&2; exit 1
fi

# 5 fields, or one of cron's @shortcuts — an expression cron rejects would make
# the whole crontab install fail, taking the user's other jobs down with it.
read -r -a _FIELDS <<< "$EXPRESSION"
case "${_FIELDS[0]}" in
    @reboot|@yearly|@annually|@monthly|@weekly|@daily|@midnight|@hourly)
        [[ ${#_FIELDS[@]} -eq 1 ]] || { echo '{"ok":false,"error":"invalid_expression"}' >&2; exit 1; } ;;
    *)
        [[ ${#_FIELDS[@]} -eq 5 ]] || { echo '{"ok":false,"error":"invalid_expression","message":"expression must have 5 fields"}' >&2; exit 1; } ;;
esac

TMP=$(mktemp /tmp/llstack-crontab.XXXXXXXXXX)
chmod 600 "$TMP"
trap 'rm -f "$TMP" "$TMP.err"' EXIT

if ! CURRENT=$(crontab -u "$SYS_USER" -l 2>"$TMP.err"); then
    if grep -qi 'no crontab' "$TMP.err"; then
        CURRENT=""
    else
        echo ">>> crontab -l failed:" >&2; cat "$TMP.err" >&2 || true
        echo '{"ok":false,"error":"crontab_read_failed","message":"refusing to rewrite a crontab that could not be read"}' >&2
        exit 1
    fi
fi

ADDED=$(CRONTAB_IN="$CURRENT" python3 - "$EXPRESSION" "$COMMAND" "$TMP" <<'PYEOF'
import os, sys

expression, command, out_path = sys.argv[1:4]

BEGIN = "# --- BEGIN LLSTACK MANAGED (rebuilt by cron-sync.sh; do not edit) ---"
END = "# --- END LLSTACK MANAGED ---"

entry = "%s %s" % (expression.strip(), command.strip())

lines = os.environ.get("CRONTAB_IN", "").splitlines()

before, managed, after = [], [], []
state = "before"
for line in lines:
    stripped = line.strip()
    if stripped == BEGIN:
        state = "inside"
        continue
    if stripped == END:
        state = "after"
        continue
    {"before": before, "inside": managed, "after": after}[state].append(line)

added = 1
if entry in [x.strip() for x in managed]:
    added = 0
else:
    managed.append(entry)

out = list(before)
while out and not out[-1].strip():
    out.pop()
if managed:
    if out:
        out.append("")
    out.append(BEGIN)
    out.extend(managed)
    out.append(END)
out.extend(after)

with open(out_path, "w") as f:
    if out:
        f.write("\n".join(out) + "\n")

print(added)
PYEOF
) || { echo '{"ok":false,"error":"crontab_build_failed"}' >&2; exit 1; }

if ! crontab -u "$SYS_USER" "$TMP" >&2; then
    echo '{"ok":false,"error":"crontab_install_failed","message":"cron rejected the crontab; nothing was changed"}' >&2
    exit 1
fi

echo ">>> $SYS_USER: added=$ADDED ($EXPRESSION)" >&2
echo "{\"ok\":true,\"data\":{\"user\":\"$SYS_USER\",\"added\":$ADDED}}"
