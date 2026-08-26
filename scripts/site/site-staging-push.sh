#!/bin/bash
set -euo pipefail

# Push staging site to production (overwrite production with staging content)
# Usage: site-staging-push.sh --staging-domain <domain> --prod-domain <domain> \
#        --mode <all|files|database> [--staging-db <db>] [--prod-db <db>]
#
# Unknown arguments are rejected rather than ignored: this script overwrites a
# production site, and a mistyped `--mode fles` silently fell through to the
# default `all`, pushing the database too.
#
# Progress goes to stderr; stdout carries only the final JSON document, because
# the backend parses the whole of stdout with json.loads().

STAGING_DOMAIN="" PROD_DOMAIN="" MODE="all"
STAGING_DB="" PROD_DB=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --staging-domain) STAGING_DOMAIN="${2:-}"; shift 2 ;;
        --prod-domain)    PROD_DOMAIN="${2:-}"; shift 2 ;;
        --mode)           MODE="${2:-}"; shift 2 ;;
        --staging-db)     STAGING_DB="${2:-}"; shift 2 ;;
        --prod-db)        PROD_DB="${2:-}"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg","message":"unrecognised argument; refusing to push"}' >&2; exit 1 ;;
    esac
done

if [[ -z "$STAGING_DOMAIN" || -z "$PROD_DOMAIN" ]]; then
    echo '{"ok":false,"error":"missing_args"}' >&2; exit 1
fi

validate_domain() {
    echo "$1" | grep -qP '^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'
}
if ! validate_domain "$STAGING_DOMAIN" || ! validate_domain "$PROD_DOMAIN"; then
    echo '{"ok":false,"error":"invalid_domain"}' >&2; exit 1
fi

if [[ "$STAGING_DOMAIN" == "$PROD_DOMAIN" ]]; then
    echo '{"ok":false,"error":"same_domain","message":"staging and production domains are identical"}' >&2; exit 1
fi

if [[ "$MODE" != "all" && "$MODE" != "files" && "$MODE" != "database" ]]; then
    echo '{"ok":false,"error":"invalid_mode","message":"mode must be all, files, or database"}' >&2; exit 1
fi

# DB names are passed to mysqldump/mysql as arguments and spliced into the
# wp_options UPDATE below
validate_db() {
    [[ "$1" =~ ^[A-Za-z0-9_]{1,64}$ ]]
}
if [[ -n "$STAGING_DB" ]] && ! validate_db "$STAGING_DB"; then
    echo '{"ok":false,"error":"invalid_db_name","message":"--staging-db must match [A-Za-z0-9_]"}' >&2; exit 1
fi
if [[ -n "$PROD_DB" ]] && ! validate_db "$PROD_DB"; then
    echo '{"ok":false,"error":"invalid_db_name","message":"--prod-db must match [A-Za-z0-9_]"}' >&2; exit 1
fi

# A database push with no databases named used to print "Step 3: Skipped" and
# still report ok:true, so the panel showed a successful push that moved nothing.
if [[ "$MODE" == "database" || "$MODE" == "all" ]]; then
    if [[ -z "$STAGING_DB" || -z "$PROD_DB" ]]; then
        if [[ "$MODE" == "database" ]]; then
            echo '{"ok":false,"error":"missing_db_args","message":"--staging-db and --prod-db are required for mode=database"}' >&2
            exit 1
        fi
        echo ">>> No databases given — pushing files only" >&2
        MODE="files"
    fi
fi

STAGING_VHOST="/usr/local/lsws/conf/vhosts/$STAGING_DOMAIN"
PROD_VHOST="/usr/local/lsws/conf/vhosts/$PROD_DOMAIN"

_get_docroot() {
    grep -oP 'docRoot\s+\K\S+' "$1/vhconf.conf" 2>/dev/null || echo ""
}
STAGING_ROOT=$(_get_docroot "$STAGING_VHOST")
PROD_ROOT=$(_get_docroot "$PROD_VHOST")

if [[ -z "$STAGING_ROOT" || -z "$PROD_ROOT" ]]; then
    echo '{"ok":false,"error":"docroot_not_found"}' >&2; exit 1
fi
if [[ ! -d "$STAGING_ROOT" || ! -d "$PROD_ROOT" ]]; then
    echo '{"ok":false,"error":"docroot_missing","message":"docRoot from vhconf does not exist on disk"}' >&2; exit 1
fi

# Step 1: Backup production before push
echo ">>> Step 1: Backing up production..." >&2
BACKUP_DIR="/opt/llstack/backups/staging-push-$(date +%Y%m%d%H%M%S)"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

FILES_BACKUP=""
DB_BACKUP=""

if [[ "$MODE" == "all" || "$MODE" == "files" ]]; then
    if ! cp -a "$PROD_ROOT" "$BACKUP_DIR/files" >&2; then
        echo '{"ok":false,"error":"backup_failed","message":"Failed to backup production files"}' >&2
        exit 1
    fi
    FILES_BACKUP="$BACKUP_DIR/files"
    echo "    Files backed up to $FILES_BACKUP" >&2
fi

if [[ "$MODE" == "all" || "$MODE" == "database" ]]; then
    if ! mysqldump --single-transaction --routines --triggers "$PROD_DB" > "$BACKUP_DIR/db.sql" 2>>"$BACKUP_DIR/backup.err"; then
        echo ">>> mysqldump stderr:" >&2; tail -5 "$BACKUP_DIR/backup.err" >&2 || true
        echo '{"ok":false,"error":"backup_failed","message":"Failed to backup production database"}' >&2
        exit 1
    fi
    # A dump that exits 0 but produced nothing means the wrong database name
    if [[ ! -s "$BACKUP_DIR/db.sql" ]]; then
        echo '{"ok":false,"error":"backup_empty","message":"Production dump is empty — refusing to overwrite"}' >&2
        exit 1
    fi
    DB_BACKUP="$BACKUP_DIR/db.sql"
    echo "    Database backed up to $DB_BACKUP ($(stat -c%s "$DB_BACKUP") bytes)" >&2
fi

# Step 2: Push files
if [[ "$MODE" == "all" || "$MODE" == "files" ]]; then
    echo ">>> Step 2: Pushing files..." >&2
    if ! rsync -a --delete \
        --exclude='.git' \
        --exclude='wp-config.php' \
        --exclude='.env' \
        --exclude='.user.ini' \
        --exclude='wp-content/debug.log' \
        "$STAGING_ROOT/" "$PROD_ROOT/" >&2; then
        echo "{\"ok\":false,\"error\":\"rsync_failed\",\"message\":\"File sync failed; production files preserved in $FILES_BACKUP\"}" >&2
        exit 1
    fi

    # Ownership must follow the production site's user, never fall back to root:
    # a root-owned docRoot makes every PHP write fail.
    if PROD_OWNER=$(stat -c '%U' "$BACKUP_DIR/files" 2>/dev/null) && [[ -n "$PROD_OWNER" ]]; then
        chown -R "$PROD_OWNER:$PROD_OWNER" "$PROD_ROOT" >&2 || true
    else
        echo "    WARNING: could not determine production owner; ownership left as-is" >&2
    fi
    echo "    Files synced: $STAGING_ROOT → $PROD_ROOT" >&2
fi

# Step 3: Push database
if [[ "$MODE" == "all" || "$MODE" == "database" ]]; then
    echo ">>> Step 3: Pushing database..." >&2

    # Dump to disk first: piping mysqldump straight into mysql leaves production
    # half-overwritten when the dump dies mid-stream.
    STAGING_DUMP="$BACKUP_DIR/staging.sql"
    if ! mysqldump --single-transaction --routines --triggers "$STAGING_DB" > "$STAGING_DUMP" 2>>"$BACKUP_DIR/push.err"; then
        echo ">>> mysqldump stderr:" >&2; tail -5 "$BACKUP_DIR/push.err" >&2 || true
        echo "{\"ok\":false,\"error\":\"staging_dump_failed\",\"message\":\"Could not dump $STAGING_DB; production untouched\"}" >&2
        exit 1
    fi
    if [[ ! -s "$STAGING_DUMP" ]]; then
        echo "{\"ok\":false,\"error\":\"staging_dump_empty\",\"message\":\"Dump of $STAGING_DB is empty; production untouched\"}" >&2
        exit 1
    fi

    if ! mysql "$PROD_DB" < "$STAGING_DUMP" 2>>"$BACKUP_DIR/push.err"; then
        echo ">>> Import failed — restoring production from $DB_BACKUP" >&2
        tail -5 "$BACKUP_DIR/push.err" >&2 || true
        RESTORED=false
        if mysql "$PROD_DB" < "$DB_BACKUP" >&2 2>&1; then RESTORED=true; fi
        echo "{\"ok\":false,\"error\":\"db_import_failed\",\"message\":\"Import into $PROD_DB failed\",\"data\":{\"restored\":$RESTORED,\"db_backup\":\"$DB_BACKUP\"}}" >&2
        exit 1
    fi
    echo "    Database pushed: $STAGING_DB → $PROD_DB" >&2

    # Rewrite the staging hostname inside the imported content
    if command -v wp &>/dev/null && [[ -f "$PROD_ROOT/wp-config.php" ]]; then
        for scheme in https http; do
            wp search-replace "$scheme://$STAGING_DOMAIN" "$scheme://$PROD_DOMAIN" \
                --path="$PROD_ROOT" --all-tables --skip-columns=guid --allow-root >&2 2>&1 || true
        done
        echo "    WP domain replaced: $STAGING_DOMAIN → $PROD_DOMAIN" >&2
    else
        mysql "$PROD_DB" -e "
            UPDATE wp_options SET option_value = REPLACE(option_value, '$STAGING_DOMAIN', '$PROD_DOMAIN')
            WHERE option_name IN ('siteurl', 'home');
        " >&2 2>&1 || echo "    WARNING: wp_options update failed (non-WordPress site?)" >&2
        echo "    wp_options updated (WP-CLI not available for full replace)" >&2
    fi
fi

# Step 4: Reload LiteHttpd (only if files were changed)
if [[ "$MODE" == "all" || "$MODE" == "files" ]]; then
    echo ">>> Step 4: Reloading LiteHttpd..." >&2
    /usr/local/lsws/bin/lswsctrl reload &>/dev/null || true
fi

echo "{\"ok\":true,\"backup_dir\":\"$BACKUP_DIR\",\"data\":{\"mode\":\"$MODE\",\"staging_domain\":\"$STAGING_DOMAIN\",\"prod_domain\":\"$PROD_DOMAIN\",\"backup_dir\":\"$BACKUP_DIR\",\"files_backup\":\"$FILES_BACKUP\",\"db_backup\":\"$DB_BACKUP\"}}"
