#!/bin/bash
set -euo pipefail

# Database maintenance: check, repair, optimize, fix-definers
# Usage: db-maintenance.sh --engine <engine> --name <db_name> --action <check|repair|optimize|fix-definers>

ENGINE="" NAME="" ACTION=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --engine) ENGINE="$2"; shift 2 ;;
        --name)   NAME="$2"; shift 2 ;;
        --action) ACTION="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$ENGINE" || -z "$NAME" || -z "$ACTION" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }

if ! echo "$NAME" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,63}$'; then
    echo '{"ok":false,"error":"invalid_db_name"}' >&2; exit 1
fi

case "$ACTION" in
    check|repair|optimize|fix-definers) ;;
    *) echo '{"ok":false,"error":"invalid_action"}' >&2; exit 1 ;;
esac

case "$ENGINE" in
    mariadb|mysql)
        if [[ "$ACTION" == "fix-definers" ]]; then
            # Fix definers in views, routines, triggers, events
            echo ">>> Fixing definers in $NAME..." >&2

            # Get first valid user for this database (NAME already validated by regex)
            DB_USER=$(mysql -N -e "SELECT DISTINCT User FROM mysql.db WHERE Db='$NAME' LIMIT 1" 2>/dev/null || echo "")
            if [[ -z "$DB_USER" ]]; then
                DB_USER="root"
            fi
            # Validate DB_USER before using in SQL
            if ! echo "$DB_USER" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,31}$'; then
                DB_USER="root"
            fi
            DEFINER="\`${DB_USER}\`@\`localhost\`"

            # Fix views — use mysqldump + sed + reimport (atomic per view)
            # Read view names line-by-line to handle special chars safely
            mysql -N -e "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.VIEWS WHERE TABLE_SCHEMA='$NAME'" 2>/dev/null | while IFS= read -r view; do
                [[ -z "$view" ]] && continue
                # Escape backticks in view name for safe SQL interpolation
                safe_view="${view//\`/\`\`}"
                echo "  Fixing view: $view" >&2
                VIEW_SQL=$(mysqldump --no-data --routines=false --triggers=false --skip-add-drop-table \
                    --no-create-info "$NAME" --where="1=0" 2>/dev/null | grep -A999 "CREATE.*VIEW" | head -20)
                if [[ -n "$VIEW_SQL" ]]; then
                    FIXED=$(echo "$VIEW_SQL" | sed "s/DEFINER=\`[^\`]*\`@\`[^\`]*\`/DEFINER=$DEFINER/g")
                    mysql "$NAME" -e "START TRANSACTION; DROP VIEW IF EXISTS \`$safe_view\`; $FIXED COMMIT;" 2>/dev/null || echo "  WARNING: could not fix view $view"
                fi
            done

            # Fix routines — use ALTER (MariaDB 10.5.2+ / MySQL 8.0+), fallback to information_schema
            for RTYPE in PROCEDURE FUNCTION; do
                mysql -N -e "SELECT ROUTINE_NAME FROM INFORMATION_SCHEMA.ROUTINES WHERE ROUTINE_SCHEMA='$NAME' AND ROUTINE_TYPE='$RTYPE'" 2>/dev/null | while IFS= read -r routine; do
                    [[ -z "$routine" ]] && continue
                    safe_routine="${routine//\`/\`\`}"
                    echo "  Fixing $RTYPE: $routine" >&2
                    mysql "$NAME" -e "ALTER $RTYPE \`$safe_routine\` SQL SECURITY DEFINER" 2>/dev/null || \
                    echo "  WARNING: ALTER $RTYPE failed for $routine (may need manual fix)" >&2
                done
            done

            echo "[fix-definers completed]" >&2
            echo '{"ok":true,"data":{"action":"fix-definers","definer":"'"$DEFINER"'"}}'
        else
            # Get all tables
            TABLES=$(mysql -N -e "SELECT TABLE_NAME FROM INFORMATION_SCHEMA.TABLES WHERE TABLE_SCHEMA='$NAME' AND TABLE_TYPE='BASE TABLE'" 2>/dev/null)
            [[ -z "$TABLES" ]] && { echo '{"ok":true,"data":{"action":"'"$ACTION"'","tables":0}}'; exit 0; }

            SQL_ACTION=$(echo "$ACTION" | tr '[:lower:]' '[:upper:]')
            TABLE_COUNT=0
            ERRORS=0

            # Feed the loop from a here-string on `done` (NOT on `read`, which would
            # re-open it every iteration and loop forever on the first line) so the
            # loop runs in the current shell and the counters persist to the output.
            # Progress goes to stderr so stdout stays parseable JSON.
            while IFS= read -r table; do
                [[ -z "$table" ]] && continue
                safe_table="${table//\`/\`\`}"
                echo ">>> $SQL_ACTION TABLE \`$NAME\`.\`$safe_table\`" >&2
                RESULT=$(mysql -e "$SQL_ACTION TABLE \`$NAME\`.\`$safe_table\`" 2>&1) || true
                echo "$RESULT" >&2
                if echo "$RESULT" | grep -qi "error"; then
                    ERRORS=$((ERRORS + 1))
                fi
                TABLE_COUNT=$((TABLE_COUNT + 1))
            done <<< "$TABLES"

            echo "[${ACTION} completed: ${TABLE_COUNT} tables, ${ERRORS} errors]" >&2
            echo "{\"ok\":true,\"data\":{\"action\":\"$ACTION\",\"tables\":$TABLE_COUNT,\"errors\":$ERRORS}}"
        fi
        ;;
    postgresql)
        case "$ACTION" in
            check)
                echo ">>> Running ANALYZE on $NAME..." >&2
                sudo -u postgres psql "$NAME" -c "ANALYZE VERBOSE;" >&2 2>&1
                echo '{"ok":true,"data":{"action":"analyze"}}'
                ;;
            optimize)
                echo ">>> Running VACUUM ANALYZE on $NAME..." >&2
                sudo -u postgres psql "$NAME" -c "VACUUM ANALYZE;" >&2 2>&1
                echo '{"ok":true,"data":{"action":"vacuum_analyze"}}'
                ;;
            repair)
                echo ">>> Running REINDEX on $NAME..." >&2
                sudo -u postgres psql "$NAME" -c "REINDEX DATABASE \"$NAME\";" >&2 2>&1
                echo '{"ok":true,"data":{"action":"reindex"}}'
                ;;
            fix-definers)
                echo "PostgreSQL does not use definers" >&2
                echo '{"ok":true,"data":{"action":"fix-definers","message":"not_applicable"}}'
                ;;
        esac
        ;;
    *) echo '{"ok":false,"error":"unsupported_engine"}' >&2; exit 1 ;;
esac
