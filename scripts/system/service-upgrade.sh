#!/bin/bash
set -euo pipefail

# Upgrade a service to the latest packaged version
# Usage: service-upgrade.sh --service <mariadb|postgresql|redis> --action <check|upgrade>
#
# Progress and dnf/systemctl output go to stderr; stdout carries only the final
# JSON document, because the backend parses the whole of stdout with json.loads().
#
# An upgrade that installs but leaves the service dead used to report ok:true
# with a "status" field nobody looked at. It now fails loudly and undoes the dnf
# transaction it created, so a failed minor upgrade does not take the database
# offline until someone reads the panel closely.

SERVICE="" ACTION=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --service) SERVICE="${2:-}"; shift 2 ;;
        --action)  ACTION="${2:-}"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$SERVICE" || -z "$ACTION" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }

case "$SERVICE" in
    mariadb) PKG="MariaDB-server" SVC="mariadb" ;;
    postgresql)
        # Detect versioned PGDG install (postgresql16-server, postgresql17-server, etc.)
        PKG="postgresql-server" SVC="postgresql"
        for ver in 18 17 16 15 14; do
            if rpm -q "postgresql${ver}-server" &>/dev/null; then
                PKG="postgresql${ver}-server"
                SVC="postgresql-${ver}"
                break
            fi
        done
        ;;
    redis)
        # Detect Redis or Valkey
        if rpm -q valkey &>/dev/null; then
            PKG="valkey" SVC="valkey"
        else
            PKG="redis" SVC="redis"
        fi
        ;;
    *) echo '{"ok":false,"error":"unsupported_service"}' >&2; exit 1 ;;
esac

# Newest dnf transaction id. The first field of the first data row is the id on
# both dnf4 and dnf5, whose table headers differ in everything else.
latest_tid() {
    dnf history list 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {print $1; exit}'
}

CURRENT=$(rpm -q "$PKG" 2>/dev/null | head -1 || echo "not_installed")

case "$ACTION" in
    check)
        # dnf check-update exits 100 when updates exist, 0 when none — neither is an error
        UPDATES=$(dnf check-update "$PKG" 2>/dev/null | awk -v p="$PKG" '$1 ~ "^"p"\\." {print $2; exit}' || true)
        if [[ -n "$UPDATES" ]]; then
            echo "{\"ok\":true,\"data\":{\"service\":\"$SERVICE\",\"package\":\"$PKG\",\"current\":\"$CURRENT\",\"available\":\"$UPDATES\",\"update_available\":true}}"
        else
            echo "{\"ok\":true,\"data\":{\"service\":\"$SERVICE\",\"package\":\"$PKG\",\"current\":\"$CURRENT\",\"update_available\":false}}"
        fi
        ;;
    upgrade)
        if [[ "$CURRENT" == "not_installed" ]]; then
            echo "{\"ok\":false,\"error\":\"not_installed\",\"message\":\"$PKG is not installed\"}" >&2
            exit 1
        fi

        echo ">>> Upgrading $SERVICE ($CURRENT)..." >&2

        # Only restart what was already running: starting a service the operator
        # had deliberately stopped is not an upgrade's business.
        WAS_ACTIVE=false
        systemctl is-active --quiet "$SVC" && WAS_ACTIVE=true

        BEFORE_TID=$(latest_tid)

        if ! dnf update -y "$PKG" >&2; then
            echo "{\"ok\":false,\"error\":\"dnf_failed\",\"message\":\"dnf update $PKG failed; nothing was restarted\"}" >&2
            exit 1
        fi

        AFTER_TID=$(latest_tid)
        UPGRADED=false
        [[ -n "$AFTER_TID" && "$AFTER_TID" != "$BEFORE_TID" ]] && UPGRADED=true

        AFTER=$(rpm -q "$PKG" 2>/dev/null | head -1 || echo "unknown")

        if [[ "$UPGRADED" != true ]]; then
            echo ">>> Already at the latest version; no restart needed" >&2
            echo "{\"ok\":true,\"data\":{\"service\":\"$SERVICE\",\"package\":\"$PKG\",\"previous\":\"$CURRENT\",\"current\":\"$AFTER\",\"upgraded\":false,\"restarted\":false,\"status\":\"$(systemctl is-active "$SVC" 2>/dev/null || echo unknown)\"}}"
            exit 0
        fi

        RESTARTED=false
        if [[ "$WAS_ACTIVE" == true ]]; then
            echo ">>> Restarting $SVC..." >&2
            systemctl restart "$SVC" >&2 || true
            RESTARTED=true

            # systemctl restart returns before a database has finished recovery
            for _ in $(seq 1 30); do
                systemctl is-active --quiet "$SVC" && break
                sleep 1
            done

            if ! systemctl is-active --quiet "$SVC"; then
                echo ">>> $SVC failed to come back after the upgrade — rolling back transaction $AFTER_TID" >&2
                journalctl -u "$SVC" -n 20 --no-pager >&2 2>/dev/null || true

                ROLLED_BACK=false
                if dnf history undo -y "$AFTER_TID" >&2; then
                    ROLLED_BACK=true
                    systemctl start "$SVC" >&2 || true
                    sleep 2
                fi
                STATUS=$(systemctl is-active "$SVC" 2>/dev/null || echo "failed")

                echo "{\"ok\":false,\"error\":\"service_failed_after_upgrade\",\"message\":\"$SVC did not come back after upgrading to $AFTER\",\"data\":{\"service\":\"$SERVICE\",\"previous\":\"$CURRENT\",\"current\":\"$AFTER\",\"rolled_back\":$ROLLED_BACK,\"status\":\"$STATUS\",\"rollback_tid\":\"$AFTER_TID\"}}" >&2
                exit 1
            fi
        fi

        STATUS=$(systemctl is-active "$SVC" 2>/dev/null || echo "inactive")
        echo ">>> Upgrade complete: $CURRENT → $AFTER (status: $STATUS)" >&2
        echo "{\"ok\":true,\"data\":{\"service\":\"$SERVICE\",\"package\":\"$PKG\",\"previous\":\"$CURRENT\",\"current\":\"$AFTER\",\"upgraded\":true,\"restarted\":$RESTARTED,\"status\":\"$STATUS\",\"rollback_tid\":\"$AFTER_TID\"}}"
        ;;
    *)
        echo '{"ok":false,"error":"invalid_action"}' >&2; exit 1
        ;;
esac
