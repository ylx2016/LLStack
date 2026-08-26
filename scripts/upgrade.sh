#!/bin/bash
set -euo pipefail

# LLStack Panel Upgrade Script
# Usage: upgrade.sh [--version <tag>] [--dev] [--force-downgrade]

LLSTACK_DIR="/opt/llstack"
# See install.sh for the rationale. A fork user (or a CI build) needs to
# be able to override which repo the upgrade pulls from, and ideally pin
# to a specific commit so two upgrades a week apart don't silently get
# different code.
LLSTACK_REPO="${LLSTACK_REPO:-https://github.com/web-casa/LLStack}"
LLSTACK_COMMIT="${LLSTACK_COMMIT:-}"
TARGET_VERSION=""
USE_DEV=false
FORCE_DOWNGRADE=false
KEEP_BACKUPS=3

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

log()  { echo -e "${GREEN}[LLStack Upgrade]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)          TARGET_VERSION="$2"; shift 2 ;;
        --dev)              USE_DEV=true; shift ;;
        --force-downgrade)  FORCE_DOWNGRADE=true; shift ;;
        *) err "Unknown argument: $1"; exit 1 ;;
    esac
done

# Check root
if [[ $EUID -ne 0 ]]; then
    err "Must be run as root"
    exit 1
fi

# Check existing installation
if [[ ! -d "$LLSTACK_DIR" ]]; then
    err "LLStack not found at $LLSTACK_DIR. Run install.sh first."
    exit 1
fi

# Dev mode must be explicit: a leftover /opt/llstack-panel must never silently
# override an explicitly requested --version.
if [[ "$USE_DEV" == true && ! -d "/opt/llstack-panel" ]]; then
    err "--dev requested but /opt/llstack-panel does not exist"
    exit 1
fi
if [[ "$USE_DEV" == true && -n "$TARGET_VERSION" ]]; then
    err "--dev and --version are mutually exclusive"
    exit 1
fi

CURRENT_VER=$(cat "$LLSTACK_DIR/VERSION" 2>/dev/null || echo "0.0.0")

# Refuse to install an older release over a migrated schema (migrations are one-way).
ver_lt() { [[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$1" && "$1" != "$2" ]]; }
if [[ -n "$TARGET_VERSION" && "$FORCE_DOWNGRADE" != true ]]; then
    TGT="${TARGET_VERSION#v}"
    if ver_lt "$TGT" "$CURRENT_VER"; then
        err "Refusing to downgrade $CURRENT_VER -> $TGT (migrations are one-way). Use --force-downgrade to override."
        exit 1
    fi
fi
MIN_VER=$(python3 -c "import json;print(json.load(open('$LLSTACK_DIR/versions.json')).get('min_upgrade_version',''))" 2>/dev/null || echo "")
if [[ -n "$MIN_VER" ]] && ver_lt "$CURRENT_VER" "$MIN_VER"; then
    err "Installed version $CURRENT_VER is below min_upgrade_version $MIN_VER — upgrade in steps or reinstall."
    exit 1
fi

# Disk space precheck (a failed half-upgrade is far worse than refusing to start)
AVAIL_MB=$(df -BM --output=avail /opt 2>/dev/null | tail -1 | tr -dc '0-9')
if [[ -n "$AVAIL_MB" && "$AVAIL_MB" -lt 1024 ]]; then
    err "Less than 1GB free on /opt (${AVAIL_MB}MB) — aborting"
    exit 1
fi

log "Starting upgrade from $CURRENT_VER..."

# ── 1. Backup everything the upgrade overwrites ──
# .venv is rebuilt from requirements.txt and backups/ is the backup target itself.
BACKUP_DIR="/opt/llstack-backup-$(date +%Y%m%d%H%M%S)"
log "Backing up to $BACKUP_DIR..."
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
rsync -a --exclude '.venv' --exclude 'backups/' --exclude '__pycache__' \
    "$LLSTACK_DIR/" "$BACKUP_DIR/"
# WAL-safe copy of the live panel database
if [[ -f "$LLSTACK_DIR/data/llstack.db" ]]; then
    sqlite3 "$LLSTACK_DIR/data/llstack.db" ".backup '$BACKUP_DIR/data/llstack.db'" 2>/dev/null || true
fi

restore_hint() {
    err "Restore with:"
    err "  systemctl stop llstack"
    err "  rsync -a --delete --exclude '.venv' --exclude 'backups/' $BACKUP_DIR/ $LLSTACK_DIR/"
    err "  systemctl start llstack"
}

# ── 2. Fetch the new version ──
log "Downloading new version..."
if [[ "$USE_DEV" == true ]]; then
    log "Dev mode: syncing from /opt/llstack-panel"
    # Refuse symlinks at the dev source, same reasoning as install.sh: a
    # privileged local user could plant a symlink at /opt/llstack-panel and
    # have arbitrary code copied in as root.
    if [[ -L "/opt/llstack-panel" ]]; then
        err "/opt/llstack-panel is a symlink; refusing to upgrade (would let a local user inject code run as root)"
        exit 1
    fi
    if [[ ! -d "/opt/llstack-panel" ]]; then
        err "/opt/llstack-panel does not exist or is not a directory"
        exit 1
    fi
    SRC="/opt/llstack-panel"
else
    SRC=$(mktemp -d)
    # The trap must use single-quotes around the whole body so $SRC is expanded
    # at trap-FIRE time, not at trap-SET time. With double quotes, the literal
    # string `rm -rf '$SRC'` was stored and the tmp dir leaked on every upgrade.
    trap 'rm -rf "$SRC"' EXIT
    # Priority for what we check out at the target ref, in order:
    #   1. --version <sha-or-tag> on the command line (operator's choice)
    #   2. LLSTACK_COMMIT env (CI / reproducible build)
    #   3. default branch HEAD (current behaviour when nothing is set)
    # `--branch` accepts tags, branch names, and commit SHAs in git, so the
    # same code path covers all three.
    ref=""
    [[ -n "$TARGET_VERSION" ]] && ref="$TARGET_VERSION"
    [[ -z "$ref" && -n "$LLSTACK_COMMIT" ]] && ref="$LLSTACK_COMMIT"
    if [[ -n "$ref" ]]; then
        git clone --depth 1 --branch "$ref" "$LLSTACK_REPO" "$SRC" 2>&1 | tail -1
    else
        git clone --depth 1 "$LLSTACK_REPO" "$SRC" 2>&1 | tail -1
    fi
    if [[ ! -f "$SRC/VERSION" ]]; then
        err "Downloaded tree has no VERSION file — aborting"
        exit 1
    fi
fi

# Stage backend/app into a new dir and swap atomically, so an interrupted sync
# can't leave migrations/ missing (which makes the panel unbootable).
if [[ -d "$SRC/backend/app" ]]; then
    rm -rf "$LLSTACK_DIR/backend/app.new"
    rsync -a "$SRC/backend/app/" "$LLSTACK_DIR/backend/app.new/"
    rm -rf "$LLSTACK_DIR/backend/app"
    mv "$LLSTACK_DIR/backend/app.new" "$LLSTACK_DIR/backend/app"
fi

# --delete on code trees: without it, scripts removed upstream stay on disk and
# keep matching the sudoers wildcard, and stale web/dist chunks accumulate.
rsync -a --delete --exclude 'node_modules' --exclude '.venv' --exclude '__pycache__' \
    --exclude 'app/' --exclude 'app.new/' \
    "$SRC/backend/" "$LLSTACK_DIR/backend/"
rsync -a --delete --exclude 'node_modules' "$SRC/web/" "$LLSTACK_DIR/web/"
rsync -a --delete "$SRC/scripts/" "$LLSTACK_DIR/scripts/"
[[ -d "$SRC/templates" ]] && rsync -a --delete "$SRC/templates/" "$LLSTACK_DIR/templates/"
[[ -d "$SRC/config" ]] && rsync -a --delete "$SRC/config/" "$LLSTACK_DIR/config/"
# VERSION / versions.json in BOTH modes, or version-check reports stale forever
cp "$SRC/VERSION" "$LLSTACK_DIR/VERSION" 2>/dev/null || true
cp "$SRC/versions.json" "$LLSTACK_DIR/versions.json" 2>/dev/null || true

# ── 3. Python dependencies ──
log "Updating Python dependencies..."
if ! "$LLSTACK_DIR/backend/.venv/bin/pip" install -q -r "$LLSTACK_DIR/backend/requirements.txt"; then
    err "pip install failed"
    restore_hint
    exit 1
fi

# ── 4. Frontend is pre-built ──
log "Frontend dist/ updated (no build needed)"

# ── 5. Database migrations ──
# Migrations run inside create_app(); a partially-applied multi-statement migration
# is not recorded and will re-run on next boot, so keep the pre-migration DB copy.
log "Running migrations..."
cd "$LLSTACK_DIR/backend"
if ! LLSTACK_DB_PATH="$LLSTACK_DIR/data/llstack.db" .venv/bin/python -c "
from app import create_app
create_app()
print('Migrations applied')
"; then
    err "Database migration FAILED — the panel may not start."
    err "Pre-migration database: $BACKUP_DIR/data/llstack.db"
    restore_hint
    exit 1
fi

# ── 6. Permissions ──
# Keep code root-owned so the service account can't rewrite a script that sudoers
# lets it run as root; only mutable state belongs to the panel user.
chown -R root:root "$LLSTACK_DIR"
chmod 755 "$LLSTACK_DIR"
chown -R llstack:llstack "$LLSTACK_DIR/data" "$LLSTACK_DIR/logs" "$LLSTACK_DIR/backups" 2>/dev/null || true
chmod 750 "$LLSTACK_DIR/data" "$LLSTACK_DIR/logs" "$LLSTACK_DIR/backups" 2>/dev/null || true
chmod +x "$LLSTACK_DIR/scripts"/*/*.sh 2>/dev/null || true
chmod +x "$LLSTACK_DIR/scripts"/*.sh 2>/dev/null || true
chmod +x "$LLSTACK_DIR/scripts/llstack-ctl" 2>/dev/null || true
ln -sf "$LLSTACK_DIR/scripts/llstack-ctl" /usr/local/bin/llstack-ctl 2>/dev/null || true

# ── 7. Restart ──
# If we were spawned by the panel itself (gunicorn inside llstack.service), a
# synchronous `systemctl restart` would SIGTERM this script via the unit's cgroup.
# Queue the restart instead and let systemd do it after we exit.
IN_UNIT=false
grep -q 'llstack\.service' /proc/self/cgroup 2>/dev/null && IN_UNIT=true

if [[ "$IN_UNIT" == true ]]; then
    log "Running inside llstack.service — queueing restart (verification deferred)"
    systemctl restart llstack --no-block 2>/dev/null || true
    NEW_VER=$(cat "$LLSTACK_DIR/VERSION" 2>/dev/null || echo "unknown")
    log "Upgrade staged! Version: $NEW_VER (service restart queued)"
    log "Backup saved at: $BACKUP_DIR"
    exit 0
fi

log "Restarting LLStack..."
if systemctl list-unit-files llstack.service &>/dev/null && \
   systemctl cat llstack.service &>/dev/null; then
    systemctl restart llstack
else
    # No systemd unit — fall back to a bare gunicorn
    pkill -f "gunicorn.*serve_app" 2>/dev/null || true
    sleep 1
    cd "$LLSTACK_DIR/backend"
    LLSTACK_DB_PATH="$LLSTACK_DIR/data/llstack.db" \
        .venv/bin/gunicorn -w 1 --threads 4 -b 127.0.0.1:8001 serve_app:app --daemon \
        --log-file /var/log/llstack.log --timeout 120
fi

# ── 8. Verify via the health endpoint (works for both start methods) ──
HEALTHY=false
for _ in $(seq 1 15); do
    sleep 1
    if curl -sf --max-time 3 http://127.0.0.1:8001/api/health 2>/dev/null | grep -q '"db"'; then
        HEALTHY=true
        break
    fi
done

if [[ "$HEALTHY" == true ]]; then
    NEW_VER=$(cat "$LLSTACK_DIR/VERSION" 2>/dev/null || echo "unknown")
    log "Upgrade complete! Version: $NEW_VER"
    log "Backup saved at: $BACKUP_DIR"
    # Prune old upgrade backups
    # shellcheck disable=SC2012
    ls -1dt /opt/llstack-backup-* 2>/dev/null | tail -n +$((KEEP_BACKUPS + 1)) | while read -r old; do
        rm -rf "$old"
    done
else
    err "Upgrade may have failed — /api/health did not respond."
    err "Check: journalctl -u llstack --no-pager -n 30"
    restore_hint
    exit 1
fi
