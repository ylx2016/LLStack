#!/bin/bash
set -euo pipefail
# Report LiteHttpd service status as JSON.
#
# Every value is captured first and then validated: `systemctl is-active` and
# `grep -c` both print a value AND exit non-zero in the common cases (service
# stopped / zero matches), so a trailing `|| echo 0` would append a second line
# and emit invalid JSON.

STATUS=$(systemctl is-active lshttpd 2>/dev/null | head -1 || true)
[[ -z "$STATUS" ]] && STATUS="not_installed"

# The running process is `litespeed` (openlitespeed is the package name), so match
# the same set the rest of the tree uses.
PID=$(pgrep -f 'litespeed|lshttpd' 2>/dev/null | head -1 || true)
[[ "$PID" =~ ^[0-9]+$ ]] || PID=0

CONNS=$(ss -tn 2>/dev/null | grep -cE ':(80|443)[[:space:]]' || true)
[[ "$CONNS" =~ ^[0-9]+$ ]] || CONNS=0

printf '{"ok":true,"data":{"status":"%s","pid":%s,"connections":%s}}\n' "$STATUS" "$PID" "$CONNS"
