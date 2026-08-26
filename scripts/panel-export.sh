#!/bin/bash
set -euo pipefail

# Export panel configuration for migration to another server
# Usage: panel-export.sh [--output <path>]
# Exports: panel database, vhost configs, .htaccess files, SSL certs, PHP configs
#
# The archive contains SSL private keys and the panel database (password hashes,
# TOTP secrets), so it is written 0600 under the panel's backups directory rather
# than into world-readable /tmp.
#
# Progress goes to stderr; stdout carries only the final JSON document.

OUTPUT=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output) OUTPUT="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

LLSTACK_DIR="${LLSTACK_DIR:-/opt/llstack}"
DB_PATH="${LLSTACK_DB_PATH:-$LLSTACK_DIR/data/llstack.db}"
PANEL_VERSION=$(cat "$LLSTACK_DIR/VERSION" 2>/dev/null || echo "unknown")

umask 077

if [[ -z "$OUTPUT" ]]; then
    mkdir -p "$LLSTACK_DIR/backups"
    chmod 750 "$LLSTACK_DIR/backups" 2>/dev/null || true
    OUTPUT="$LLSTACK_DIR/backups/llstack-export-$(date +%Y%m%d%H%M%S).tar.gz"
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo ">>> Exporting LLStack panel configuration..." >&2

ERRORS=0
warn() { echo "    WARNING: $*" >&2; ERRORS=$((ERRORS + 1)); }

# 1. Panel database — must use sqlite3 .backup, not cp.
# The DB runs in WAL mode with synchronous=NORMAL, so recent commits live only in
# the -wal file; a plain cp silently produces an archive missing the newest sites,
# users and settings.
echo "  Database..." >&2
mkdir -p "$TMPDIR/data"
if [[ -f "$DB_PATH" ]]; then
    if ! sqlite3 "$DB_PATH" ".backup '$TMPDIR/data/llstack.db'" 2>/dev/null; then
        warn "sqlite3 .backup failed; falling back to cp (may miss recent commits)"
        cp "$DB_PATH" "$TMPDIR/data/llstack.db" || warn "database copy failed"
    fi
else
    echo '{"ok":false,"error":"db_not_found","message":"'"$DB_PATH"' does not exist"}' >&2
    exit 1
fi
cp "$LLSTACK_DIR/data/.llstack_"* "$TMPDIR/data/" 2>/dev/null || true

# 2. Vhost configurations
echo "  Vhost configs..." >&2
mkdir -p "$TMPDIR/vhosts"
VHOST_COUNT=0
for vdir in /usr/local/lsws/conf/vhosts/*/; do
    [[ -d "$vdir" ]] || continue
    domain=$(basename "$vdir")
    mkdir -p "$TMPDIR/vhosts/$domain"
    if cp "$vdir/vhconf.conf" "$TMPDIR/vhosts/$domain/" 2>/dev/null; then
        VHOST_COUNT=$((VHOST_COUNT + 1))
    fi
done

# 3. SSL certificates
# Earlier this matched only `*.pem`, but acme.sh's default names include
# `fullchain.cer`, `domain.cer`, `ca.cer`, `domain.key` and `*.chain.pem` — so
# most real installs exported zero cert files while still counting the directory
# as "success". Match the broader set.
echo "  SSL certificates..." >&2
mkdir -p "$TMPDIR/ssl"
SSL_COUNT=0
for sdir in /usr/local/lsws/conf/ssl/*/; do
    [[ -d "$sdir" ]] || continue
    domain=$(basename "$sdir")
    mkdir -p "$TMPDIR/ssl/$domain"
    # Nullglob so an empty directory doesn't make cp receive the literal "*.pem"
    # argument. shopt is per-shell so save/restore around the loop.
    shopt -s nullglob
    cert_files=("$sdir"/*.pem "$sdir"/*.cer "$sdir"/*.crt "$sdir"/*.key)
    shopt -u nullglob
    if [[ ${#cert_files[@]} -gt 0 ]]; then
        cp "${cert_files[@]}" "$TMPDIR/ssl/$domain/" 2>/dev/null \
            && SSL_COUNT=$((SSL_COUNT + 1))
    else
        echo "    WARNING: $sdir has no .pem/.cer/.crt/.key files — skipping" >&2
    fi
done

# 4. httpd_config.conf (LiteHttpd main config)
echo "  LiteHttpd config..." >&2
cp /usr/local/lsws/conf/httpd_config.conf "$TMPDIR/httpd_config.conf" 2>/dev/null \
    || warn "httpd_config.conf not copied"

# 5. .htaccess files, keyed by system user AND domain.
# Keying on the domain alone collides when two users each host the same domain
# name, and the importer then cannot tell which user's site it belongs to.
echo "  .htaccess files..." >&2
mkdir -p "$TMPDIR/htaccess"
HT_COUNT=0
for htaccess in /home/*/public_html/*/.htaccess /var/www/public_html/*/.htaccess; do
    [[ -f "$htaccess" ]] || continue
    domain=$(basename "$(dirname "$htaccess")")
    owner=$(stat -c '%U' "$htaccess" 2>/dev/null || echo root)
    mkdir -p "$TMPDIR/htaccess/$owner"
    if cp "$htaccess" "$TMPDIR/htaccess/$owner/$domain.htaccess" 2>/dev/null; then
        HT_COUNT=$((HT_COUNT + 1))
    fi
done

# 6. PHP configs
echo "  PHP configs..." >&2
mkdir -p "$TMPDIR/php"
PHP_COUNT=0
for ini in /etc/opt/remi/php*/php.ini; do
    [[ -f "$ini" ]] || continue
    # Take the version from the directory name (phpXX), not a digit-grep, which
    # turns php8.3 into "8" and would restore into the wrong path.
    ver=$(basename "$(dirname "$ini")")
    if cp "$ini" "$TMPDIR/php/${ver}.ini" 2>/dev/null; then
        PHP_COUNT=$((PHP_COUNT + 1))
    fi
done

# 7. Metadata — record the real panel version so the importer can gate on it
cat > "$TMPDIR/export-info.json" << INFOEOF
{
    "exported_at": "$(date -Iseconds)",
    "hostname": "$(hostname)",
    "os": "$(. /etc/os-release; echo "$NAME $VERSION_ID")",
    "panel_version": "$PANEL_VERSION",
    "counts": {
        "vhosts": $VHOST_COUNT,
        "ssl": $SSL_COUNT,
        "htaccess": $HT_COUNT,
        "php_ini": $PHP_COUNT
    },
    "not_included": [
        "system users and /home site files",
        "MariaDB/MySQL/PostgreSQL databases and grants",
        "crontab entries (/var/spool/cron)",
        "Redis instance configs and passwords (~/.redis)",
        "acme.sh renewal state (/root/.acme.sh)",
        "cgroup limits (keyed by UID)"
    ]
}
INFOEOF

# Package
echo ">>> Creating archive..." >&2
if ! tar czf "$OUTPUT" -C "$TMPDIR" .; then
    echo '{"ok":false,"error":"archive_failed"}' >&2
    exit 1
fi
chmod 600 "$OUTPUT"

SIZE=$(stat -c%s "$OUTPUT" 2>/dev/null || echo 0)
echo ">>> Export complete: $OUTPUT ($((SIZE / 1024)) KB, $ERRORS warnings)" >&2
printf '{"ok":true,"data":{"path":"%s","size":%s,"panel_version":"%s","warnings":%s,"counts":{"vhosts":%s,"ssl":%s,"htaccess":%s,"php_ini":%s}}}\n' \
    "$OUTPUT" "$SIZE" "$PANEL_VERSION" "$ERRORS" "$VHOST_COUNT" "$SSL_COUNT" "$HT_COUNT" "$PHP_COUNT"
