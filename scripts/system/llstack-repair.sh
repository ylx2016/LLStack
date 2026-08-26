#!/bin/bash
set -euo pipefail

# LLStack repair — regenerate configurations from database state
# Usage: llstack-repair.sh [--component <vhost|php|redis|cron|all>]
#
# Regenerating a vhost used to pass only --domain/--doc-root/--php, so a repair
# silently dropped the site's aliases, its custom config blocks and its vhssl
# block: an HTTPS site came back as plain HTTP with no aliases, which looks like
# a working repair until someone loads the site. Everything the renderer accepts
# is now read back out of the database and the cert directory.
#
# Progress goes to stderr; stdout carries only the final JSON document, because
# the backend parses the whole of stdout with json.loads().

COMPONENT="all"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --component) COMPONENT="${2:-}"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

DB_PATH="${LLSTACK_DB_PATH:-/opt/llstack/data/llstack.db}"
SCRIPTS_DIR="${LLSTACK_SCRIPTS_DIR:-/opt/llstack/scripts}"
LSWS_CONF="/usr/local/lsws/conf/httpd_config.conf"
CERT_DIR="/usr/local/lsws/conf/ssl"

if [[ ! -f "$DB_PATH" ]]; then
    echo '{"ok":false,"error":"database_not_found"}' >&2; exit 1
fi

FIXED=0
ERRORS=0
WARNINGS=()

warn() { WARNINGS+=("$1"); echo "  [WARN] $1" >&2; }

repair_vhosts() {
    echo ">>> Repairing vhost configurations..." >&2

    # \x1f rather than tab: tab is IFS whitespace, so `IFS=$'\t' read` collapses
    # runs of it and a site with no aliases would shift ssl_enabled one field left
    local sites
    sites=$(python3 - "$DB_PATH" <<'PYEOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
for row in conn.execute(
        "SELECT id, domain, COALESCE(doc_root,''), COALESCE(php_version,''), "
        "COALESCE(aliases,''), COALESCE(ssl_enabled,0) "
        "FROM sites WHERE status = 'active'"):
    print("\x1f".join(str(c) for c in row))
PYEOF
) || { echo "  [ERROR] could not read sites table" >&2; ERRORS=$((ERRORS + 1)); return 0; }

    while IFS=$'\x1f' read -r site_id domain doc_root php_version aliases ssl_enabled; do
        [[ -z "${domain:-}" ]] && continue
        php_version="${php_version:-php83}"
        [[ -z "$php_version" ]] && php_version="php83"

        local vhost_dir="/usr/local/lsws/conf/vhosts/$domain"
        local vhost_conf="$vhost_dir/vhconf.conf"

        if [[ ! -f "$vhost_conf" ]]; then
            echo "  [REPAIR] Missing vhost for $domain — regenerating..." >&2

            local render_args=(--domain "$domain" --doc-root "$doc_root" --php "$php_version")
            [[ -n "$aliases" ]] && render_args+=(--aliases "$aliases")

            # Custom config blocks live in their own table; the renderer expects
            # them as a JSON file and unlinks it after reading.
            local custom_json
            custom_json=$(mktemp /tmp/llstack-repair-custom.XXXXXXXXXX.json)
            if python3 - "$DB_PATH" "$site_id" "$custom_json" <<'PYEOF'
import json, sqlite3, sys
db, site_id, out = sys.argv[1:4]
conn = sqlite3.connect(db)
try:
    rows = conn.execute(
        "SELECT hook_point, content FROM site_custom_config WHERE site_id = ?",
        (site_id,)).fetchall()
except sqlite3.Error:
    rows = []          # table predates migration 004
if not rows:
    sys.exit(1)
with open(out, "w") as f:
    json.dump({h: c for h, c in rows}, f)
PYEOF
            then
                render_args+=(--custom-json "$custom_json")
                echo "    carrying over custom config blocks" >&2
            else
                rm -f "$custom_json"
            fi

            # HTTPS is only restored when the cert is actually on disk; passing
            # missing paths would render a vhssl block pointing at nothing.
            if [[ "$ssl_enabled" == "1" ]]; then
                if [[ -f "$CERT_DIR/$domain/fullchain.pem" && -f "$CERT_DIR/$domain/privkey.pem" ]]; then
                    render_args+=(--ssl-key "$CERT_DIR/$domain/privkey.pem"
                                  --ssl-cert "$CERT_DIR/$domain/fullchain.pem")
                    echo "    carrying over SSL certificate" >&2
                else
                    warn "$domain has ssl_enabled=1 but no certificate in $CERT_DIR/$domain — rendered as HTTP only, re-issue with ssl-issue.sh"
                fi
            fi

            if "$SCRIPTS_DIR/site/site-vhost-render.sh" "${render_args[@]}" >&2; then
                FIXED=$((FIXED + 1))
            else
                ERRORS=$((ERRORS + 1))
                warn "failed to regenerate vhost for $domain"
            fi
        else
            echo "  [OK] $domain" >&2
        fi

        # A vhconf on disk that httpd_config does not reference is dead weight:
        # the site is unreachable even though every file looks right.
        if [[ -f "$LSWS_CONF" ]]; then
            if ! grep -qE "^virtualhost[[:space:]]+${domain//./\\.}[[:space:]]*\{" "$LSWS_CONF"; then
                warn "$domain has no virtualhost block in httpd_config.conf — recreate the site to re-register it"
            elif ! grep -qE "^[[:space:]]*map[[:space:]]+${domain//./\\.}([[:space:],]|$)" "$LSWS_CONF"; then
                warn "$domain is declared but not mapped onto any listener — it will not answer on :80"
            fi
        fi
    done <<< "$sites"

    # Orphaned vhost dirs (no matching DB entry) — one query for all of them
    python3 - "$DB_PATH" <<'PYEOF' >&2 || true
import os, sqlite3, sys, re
db = sys.argv[1]
base = "/usr/local/lsws/conf/vhosts"
if not os.path.isdir(base):
    sys.exit(0)
conn = sqlite3.connect(db)
known = {r[0] for r in conn.execute("SELECT domain FROM sites")}
rx = re.compile(r'^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$')
for name in sorted(os.listdir(base)):
    if not os.path.isdir(os.path.join(base, name)):
        continue
    if name in ("Example", "llstack-panel"):
        continue
    if not rx.match(name):
        print("  [WARN] Invalid vhost dir name: %s" % name)
        continue
    if name not in known:
        print("  [WARN] Orphaned vhost dir: %s (no DB entry)" % name)
PYEOF
}

repair_php() {
    echo ">>> Repairing PHP configurations..." >&2
    # The PHP registry lives in the database and is rebuilt by the API; there is
    # nothing a shell script can fix here without duplicating that logic.
    echo "  [INFO] Run 'POST /api/system/php-registry/sync' to refresh the PHP version registry" >&2
}

repair_redis() {
    echo ">>> Repairing Redis instances..." >&2

    local instances
    instances=$(python3 - "$DB_PATH" <<'PYEOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
try:
    rows = conn.execute(
        "SELECT r.id, u.system_user, COALESCE(r.status,'') FROM redis_instances r "
        "JOIN users u ON r.user_id = u.id").fetchall()
except sqlite3.Error:
    rows = []
for row in rows:
    print("\x1f".join(str(c) for c in row))
PYEOF
) || { echo "  [ERROR] could not read redis_instances" >&2; ERRORS=$((ERRORS + 1)); return 0; }

    while IFS=$'\x1f' read -r inst_id system_user status; do
        [[ -z "${system_user:-}" ]] && continue
        local service="redis@$system_user"

        local actual="stopped"
        systemctl is-active "$service" &>/dev/null && actual="running"

        if [[ "$status" != "$actual" ]]; then
            echo "  [REPAIR] Redis for $system_user: DB says '$status', actual '$actual' — updating DB" >&2
            if python3 - "$DB_PATH" "$actual" "$inst_id" <<'PYEOF'
import sqlite3, sys
db, status, inst_id = sys.argv[1:4]
conn = sqlite3.connect(db)
conn.execute("UPDATE redis_instances SET status = ? WHERE id = ?", (status, inst_id))
conn.commit()
PYEOF
            then
                FIXED=$((FIXED + 1))
            else
                ERRORS=$((ERRORS + 1))
                warn "could not update redis status for $system_user"
            fi
        else
            echo "  [OK] Redis for $system_user ($actual)" >&2
        fi
    done <<< "$instances"
}

repair_cron() {
    echo ">>> Repairing cron jobs..." >&2
    # Rebuild each user's managed crontab block from the database
    local users
    users=$(python3 - "$DB_PATH" <<'PYEOF'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
try:
    rows = conn.execute(
        "SELECT DISTINCT u.system_user FROM cron_jobs c JOIN users u ON c.user_id = u.id "
        "WHERE u.system_user IS NOT NULL AND u.system_user <> ''").fetchall()
except sqlite3.Error:
    rows = []
for (u,) in rows:
    print(u)
PYEOF
) || { echo "  [ERROR] could not read cron_jobs" >&2; ERRORS=$((ERRORS + 1)); return 0; }

    if [[ -z "$users" ]]; then
        echo "  [OK] No cron jobs to sync" >&2
        return 0
    fi

    while IFS= read -r system_user; do
        [[ -z "$system_user" ]] && continue
        if "$SCRIPTS_DIR/cron/cron-sync.sh" --user "$system_user" >&2; then
            echo "  [OK] crontab rebuilt for $system_user" >&2
            FIXED=$((FIXED + 1))
        else
            ERRORS=$((ERRORS + 1))
            warn "could not rebuild crontab for $system_user"
        fi
    done <<< "$users"
}

case "$COMPONENT" in
    vhost)  repair_vhosts ;;
    php)    repair_php ;;
    redis)  repair_redis ;;
    cron)   repair_cron ;;
    all)
        repair_vhosts
        repair_redis
        repair_cron
        ;;
    *) echo '{"ok":false,"error":"invalid_component"}' >&2; exit 1 ;;
esac

if [[ ${#WARNINGS[@]} -eq 0 ]]; then
    WARN_JSON='[]'
else
    WARN_JSON=$(printf '%s\0' "${WARNINGS[@]}" | python3 -c 'import sys, json; print(json.dumps([x.decode("utf-8", "replace") for x in sys.stdin.buffer.read().split(b"\0")[:-1]]))')
fi

echo ">>> Repair complete: $FIXED fixed, $ERRORS errors, ${#WARNINGS[@]} warnings" >&2
echo "{\"ok\":true,\"data\":{\"component\":\"$COMPONENT\",\"fixed\":$FIXED,\"errors\":$ERRORS,\"warnings\":$WARN_JSON}}"
