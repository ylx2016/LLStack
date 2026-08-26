#!/bin/bash
set -euo pipefail

# Get current cgroup resource usage and limits for a user
# Usage: cgroup-status.sh --user <system_user>

USER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --user) USER="$2"; shift 2 ;;
        *) shift ;;
    esac
done

[[ -z "$USER" ]] && { echo '{"ok":false,"error":"missing_user"}' >&2; exit 1; }

if ! id "$USER" &>/dev/null; then
    echo '{"ok":false,"error":"user_not_found"}' >&2; exit 1
fi

UID_NUM=$(id -u "$USER")
SLICE_PATH="/sys/fs/cgroup/user.slice/user-${UID_NUM}.slice"

if [[ ! -d "$SLICE_PATH" ]]; then
    echo '{"ok":true,"data":{"active":false,"message":"no cgroup slice found"}}'
    exit 0
fi

# Read current limits and usage
read_cgroup() {
    local file="$1" default="$2"
    if [[ -f "$SLICE_PATH/$file" ]]; then
        cat "$SLICE_PATH/$file" 2>/dev/null || echo "$default"
    else
        echo "$default"
    fi
}

CPU_MAX=$(read_cgroup "cpu.max" "max 100000")
MEM_MAX=$(read_cgroup "memory.max" "max")
MEM_CURRENT=$(read_cgroup "memory.current" "0")
TASKS_MAX=$(read_cgroup "pids.max" "max")
TASKS_CURRENT=$(read_cgroup "pids.current" "0")

# Parse CPU quota
CPU_QUOTA="unlimited"
if [[ "$CPU_MAX" != "max "* ]]; then
    QUOTA_US=$(echo "$CPU_MAX" | awk '{print $1}')
    PERIOD_US=$(echo "$CPU_MAX" | awk '{print $2}')
    if [[ "$QUOTA_US" != "max" && -n "$PERIOD_US" && "$PERIOD_US" -gt 0 ]]; then
        CPU_QUOTA="$((QUOTA_US * 100 / PERIOD_US))%"
    fi
fi

# Parse memory
MEM_MAX_DISPLAY="unlimited"
if [[ "$MEM_MAX" != "max" ]]; then
    MEM_MAX_DISPLAY="$((MEM_MAX / 1024 / 1024))M"
fi
MEM_CURRENT_MB="$((MEM_CURRENT / 1024 / 1024))"

# Parse tasks
TASKS_MAX_DISPLAY="$TASKS_MAX"

# Read pressure info if available
CPU_PRESSURE=""
MEM_PRESSURE=""
IO_PRESSURE=""
if [[ -f "$SLICE_PATH/cpu.pressure" ]]; then
    CPU_PRESSURE=$(head -1 "$SLICE_PATH/cpu.pressure" 2>/dev/null || echo "")
fi
if [[ -f "$SLICE_PATH/memory.pressure" ]]; then
    MEM_PRESSURE=$(head -1 "$SLICE_PATH/memory.pressure" 2>/dev/null || echo "")
fi
if [[ -f "$SLICE_PATH/io.pressure" ]]; then
    IO_PRESSURE=$(head -1 "$SLICE_PATH/io.pressure" 2>/dev/null || echo "")
fi

# Use Python for JSON serialization. Pressure strings can contain spaces
# and quotes; going through json.dumps keeps the contract consistent.
python3 - "$USER" "$UID_NUM" "$CPU_QUOTA" "$MEM_MAX_DISPLAY" \
        "$MEM_CURRENT_MB" "$TASKS_MAX_DISPLAY" "$TASKS_CURRENT" \
        "$CPU_PRESSURE" "$MEM_PRESSURE" "$IO_PRESSURE" <<'PYEOF'
import json, sys
data = {
    "ok": True,
    "data": {
        "active": True,
        "user": sys.argv[1],
        "uid": int(sys.argv[2]),
        "cpu_quota": sys.argv[3],
        "memory_max": sys.argv[4],
        "memory_current_mb": int(sys.argv[5]),
        "tasks_max": sys.argv[6],
        "tasks_current": int(sys.argv[7]),
        "cpu_pressure": sys.argv[8],
        "memory_pressure": sys.argv[9],
        "io_pressure": sys.argv[10],
    },
}
print(json.dumps(data, separators=(",", ":")))
PYEOF
