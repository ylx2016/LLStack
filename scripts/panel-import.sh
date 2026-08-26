#!/bin/bash
set -euo pipefail

# Import panel configuration from export archive
# Usage: panel-import.sh --input <archive> [--yes]
#
# Destructive: replaces the panel database, httpd_config.conf, vhost configs, SSL
# certs, .htaccess files and php.ini files. A full snapshot is taken first and
# restored automatically if the web server fails to come back up.
#
# All progress goes to stderr; stdout carries only the final JSON document.

INPUT=""
ASSUME_YES=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --input) INPUT="$2"; shift 2 ;;
        --yes)   ASSUME_YES=true; shift ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

LLSTACK_DIR="${LLSTACK_DIR:-/opt/llstack}"
DB_PATH="${LLSTACK_DB_PATH:-$LLSTACK_DIR/data/llstack.db}"
LSWS_CONF="/usr/local/lsws/conf/httpd_config.conf"

if [[ -z "$INPUT" || ! -f "$INPUT" ]]; then
    echo '{"ok":false,"error":"input_required"}' >&2
    exit 1
fi

if [[ "$ASSUME_YES" != true ]]; then
    echo '{"ok":false,"error":"confirmation_required","message":"Import replaces the panel database and web server config. Re-run with --yes."}' >&2
    exit 1
fi

TMPDIR=$(mktemp -d)
echo ">>> Importing LLStack configuration..." >&2

cd "$TMPDIR"

# Reject archives containing absolute paths, '..' components, symlinks, hardlinks,
# or device/FIFO nodes (path traversal / arbitrary-write defense). Checked BEFORE
# extraction so a hostile archive never touches the filesystem.
if tar tvzf "$INPUT" | grep -qE '^[lhbcp]' || \
   tar tzf "$INPUT" | grep -qE '(^\.\./|/\.\./|\.\.$|^/)'; then
    echo '{"ok":false,"error":"path_traversal_detected","message":"Archive contains absolute, parent, link, or device paths"}' >&2
    exit 1
fi
tar --no-same-owner --no-same-permissions --no-overwrite-dir -xzf "$INPUT"

if [[ -f export-info.json ]]; then
    echo "  Source: $(python3 -c "import json;d=json.load(open('export-info.json'));print(f'{d.get(\"hostname\")} ({d.get(\"os\")})')" 2>/dev/null || echo unknown)" >&2
fi

# Defense in depth: every entry name we derive a destination path from must be a
# plain hostname/path-safe token (no '/', no glob chars, no empty).
sanitize_name() { echo "$1" | grep -qE '^[a-zA-Z0-9._-]+$'; }

# ── Pre-import snapshot (so a bad archive is recoverable) ──
SNAP="$LLSTACK_DIR/backups/pre-import-$(date +%Y%m%d%H%M%S)"
mkdir -p "$SNAP"
chmod 700 "$SNAP"
echo ">>> Snapshotting current state to $SNAP ..." >&2
if [[ -f "$DB_PATH" ]]; then
    # WAL-safe copy of the live database
    sqlite3 "$DB_PATH" ".backup '$SNAP/llstack.db'" 2>/dev/null || cp "$DB_PATH" "$SNAP/llstack.db"
fi
[[ -f "$LSWS_CONF" ]] && cp "$LSWS_CONF" "$SNAP/httpd_config.conf"
if [[ -d /usr/local/lsws/conf/vhosts ]]; then
    tar czf "$SNAP/vhosts.tar.gz" -C /usr/local/lsws/conf vhosts 2>/dev/null || true
fi
echo "  Snapshot complete" >&2

RESTORED=false
rollback() {
    [[ "$RESTORED" == true ]] && return 0
    RESTORED=true
    echo ">>> Rolling back to $SNAP ..." >&2
    systemctl stop llstack 2>/dev/null || true
    if [[ -f "$SNAP/llstack.db" ]]; then
        rm -f "$DB_PATH" "$DB_PATH-wal" "$DB_PATH-shm"
        cp "$SNAP/llstack.db" "$DB_PATH"
    fi
    [[ -f "$SNAP/httpd_config.conf" ]] && cp "$SNAP/httpd_config.conf" "$LSWS_CONF"
    if [[ -f "$SNAP/vhosts.tar.gz" ]]; then
        tar xzf "$SNAP/vhosts.tar.gz" -C /usr/local/lsws/conf 2>/dev/null || true
    fi
    # PHP ini files were snapshotted as $SNAP/php<ver>.ini.bak at the time
    # they were overwritten (see "── 6. PHP configs ──" below). Without
    # restoring them here, a bad php.ini that takes the web server's PHP
    # down stays in place even after the user sees "rolled back".
    for bak in "$SNAP"/php*.ini.bak; do
        [[ -f "$bak" ]] || continue
        ver=$(basename "$bak" .ini.bak | sed 's/^php//')
        if [[ "$ver" =~ ^[0-9]+$ ]] && [[ -f /etc/opt/remi/php${ver}/php.ini ]]; then
            cp "$bak" "/etc/opt/remi/php${ver}/php.ini"
        fi
    done
    /usr/local/lsws/bin/lswsctrl restart &>/dev/null || true
    systemctl start llstack 2>/dev/null || true
    command -v restorecon &>/dev/null && restorecon -R /usr/local/lsws/conf "$LLSTACK_DIR/data" 2>/dev/null || true
}
trap 'rm -rf "$TMPDIR"' EXIT

# ── 1. Database ──
# The panel DB is WAL mode: the service must be stopped and the stale -wal/-shm
# discarded, or gunicorn reads a half-swapped database and old WAL frames get
# replayed into the new file ("database disk image is malformed").
if [[ -f data/llstack.db ]]; then
    echo "  Importing database..." >&2
    systemctl stop llstack 2>/dev/null || true
    rm -f "$DB_PATH-wal" "$DB_PATH-shm"
    cp data/llstack.db "$DB_PATH"
    cp data/.llstack_* "$(dirname "$DB_PATH")/" 2>/dev/null || true
    # Verify the imported database is readable before going further
    if ! sqlite3 "$DB_PATH" 'PRAGMA integrity_check;' 2>/dev/null | grep -q '^ok$'; then
        echo '{"ok":false,"error":"db_integrity_failed","message":"Imported database failed integrity check; rolled back"}' >&2
        rollback
        exit 1
    fi
fi

# ── 2. Vhost configs ──
if [[ -d vhosts ]]; then
    echo "  Importing vhost configs..." >&2
    for vdir in vhosts/*/; do
        [[ -d "$vdir" ]] || continue
        domain=$(basename "$vdir")
        sanitize_name "$domain" || { echo '{"ok":false,"error":"invalid_vhost_dir"}' >&2; rollback; exit 1; }
        DEST="/usr/local/lsws/conf/vhosts/$domain"
        mkdir -p "$DEST"
        cp "$vdir/vhconf.conf" "$DEST/" 2>/dev/null || true
    done
fi

# ── 3. SSL certs ──
if [[ -d ssl ]]; then
    echo "  Importing SSL certificates..." >&2
    for sdir in ssl/*/; do
        [[ -d "$sdir" ]] || continue
        domain=$(basename "$sdir")
        sanitize_name "$domain" || { echo '{"ok":false,"error":"invalid_ssl_dir"}' >&2; rollback; exit 1; }
        DEST="/usr/local/lsws/conf/ssl/$domain"
        mkdir -p "$DEST"
        chmod 700 "$DEST"
        cp "$sdir"/*.pem "$DEST/" 2>/dev/null || true
        chmod 600 "$DEST"/*.pem 2>/dev/null || true
    done
fi

# ── 4. httpd_config.conf ──
if [[ -f httpd_config.conf ]]; then
    echo "  Importing LiteHttpd config..." >&2
    cp httpd_config.conf "$LSWS_CONF"
fi

# ── 5. .htaccess files ──
# Current layout is htaccess/<system_user>/<domain>.htaccess; the flat
# htaccess/<domain>.htaccess form from older exports is still accepted.
if [[ -d htaccess ]]; then
    echo "  Importing .htaccess files..." >&2
    while IFS= read -r -d '' ht; do
        rel="${ht#htaccess/}"
        domain=$(basename "$rel" .htaccess)
        owner=$(dirname "$rel")
        [[ "$owner" == "." ]] && owner=""
        [[ -z "$domain" || "$domain" == "*" ]] && { echo '{"ok":false,"error":"invalid_htaccess_file"}' >&2; rollback; exit 1; }
        sanitize_name "$domain" || { echo '{"ok":false,"error":"invalid_htaccess_file"}' >&2; rollback; exit 1; }
        if [[ -n "$owner" ]]; then
            sanitize_name "$owner" || { echo '{"ok":false,"error":"invalid_htaccess_owner"}' >&2; rollback; exit 1; }
            # Prefer the recorded owner's home so same-named sites land correctly
            CANDIDATES=("/home/$owner/public_html/$domain" "/var/www/public_html/$domain")
        else
            CANDIDATES=(/home/*/public_html/"$domain" "/var/www/public_html/$domain")
        fi
        PLACED=false
        for docroot in "${CANDIDATES[@]}"; do
            if [[ -d "$docroot" ]]; then
                cp "$ht" "$docroot/.htaccess"
                PLACED=true
                break
            fi
        done
        [[ "$PLACED" == false ]] && echo "    WARNING: no docroot found for $domain — .htaccess skipped" >&2
    done < <(find htaccess -type f -name '*.htaccess' -print0)
fi

# ── 6. PHP configs ──
# Back each one up: a source php.ini may enable extensions this host lacks, which
# would take every site's PHP down.
if [[ -d php ]]; then
    echo "  Importing PHP configs..." >&2
    for ini in php/php*.ini; do
        [[ -f "$ini" ]] || continue
        ver=$(basename "$ini" .ini | sed 's/^php//')
        [[ "$ver" =~ ^[0-9]+$ ]] || { echo '{"ok":false,"error":"invalid_php_file"}' >&2; rollback; exit 1; }
        DEST="/etc/opt/remi/php${ver}/php.ini"
        if [[ -f "$DEST" ]]; then
            cp "$DEST" "$SNAP/php${ver}.ini.bak" 2>/dev/null || true
            cp "$ini" "$DEST"
        else
            echo "    WARNING: PHP $ver not installed here — php.ini skipped" >&2
        fi
    done
fi

# ── 7. Restart and verify; roll back if the web server does not come back ──
echo ">>> Restarting services..." >&2
/usr/local/lsws/bin/lswsctrl restart &>/dev/null || true
sleep 2
if ! pgrep -f 'litespeed|lshttpd|openlitespeed' &>/dev/null; then
    echo '{"ok":false,"error":"litehttpd_failed","message":"LiteHttpd did not start with the imported config; rolled back"}' >&2
    rollback
    exit 1
fi
systemctl start llstack 2>/dev/null || true

# Restore SELinux labels on everything we wrote
if command -v restorecon &>/dev/null; then
    restorecon -R /usr/local/lsws/conf "$LLSTACK_DIR/data" &>/dev/null || true
fi

echo ">>> Import complete!" >&2
printf '{"ok":true,"data":{"snapshot":"%s"}}\n' "$SNAP"
