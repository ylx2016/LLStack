#!/bin/bash
set -euo pipefail

# Check cgroups v2 support and OLS lscgctl availability
# Usage: cgroup-check.sh
# Returns JSON with support status for each feature

LSCGCTL_PATH="/usr/local/lsws/lsns/bin/lscgctl"
LSSETUP_PATH="/usr/local/lsws/lsns/bin/lssetup"

cgroups_v2=false
lscgctl_available=false
memory_controller=false
cpu_controller=false
io_controller=false
os_name="Unknown"
needs_enablement=false

# Detect OS
if [[ -f /etc/redhat-release ]]; then
    os_name=$(cat /etc/redhat-release)
fi

# Check cgroups v2 mounted
if [[ -f /sys/fs/cgroup/cgroup.controllers ]]; then
    cgroups_v2=true
    controllers=$(cat /sys/fs/cgroup/cgroup.controllers)
    [[ "$controllers" == *"memory"* ]] && memory_controller=true
    [[ "$controllers" == *"cpu"* ]] && cpu_controller=true
    [[ "$controllers" == *"io"* ]] && io_controller=true
else
    # Check if RHEL 8 needs manual enablement
    if [[ -f /etc/redhat-release ]] && grep -qi 'release 8' /etc/redhat-release; then
        needs_enablement=true
    fi
fi

# Check lscgctl
if [[ -x "$LSCGCTL_PATH" ]]; then
    if "$LSCGCTL_PATH" version &>/dev/null; then
        lscgctl_available=true
    fi
fi

# Use Python for JSON serialization. $os_name / paths could contain " or \.
python3 - "$cgroups_v2" "$lscgctl_available" "$memory_controller" \
        "$cpu_controller" "$io_controller" "$os_name" "$needs_enablement" \
        "$LSCGCTL_PATH" "$LSSETUP_PATH" <<'PYEOF'
import json, sys
data = {
    "ok": True,
    "data": {
        "cgroups_v2": sys.argv[1] == "True",
        "lscgctl_available": sys.argv[2] == "True",
        "memory_controller": sys.argv[3] == "True",
        "cpu_controller": sys.argv[4] == "True",
        "io_controller": sys.argv[5] == "True",
        "os_name": sys.argv[6],
        "needs_enablement": sys.argv[7] == "True",
        "lscgctl_path": sys.argv[8],
        "lssetup_path": sys.argv[9],
    },
}
print(json.dumps(data, separators=(",", ":")))
PYEOF
