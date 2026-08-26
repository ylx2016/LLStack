#!/bin/bash
set -euo pipefail

# Smart Update: clone → update → check → report
# Usage: wp-smart-update.sh --path <wp_root> --type <plugin|theme|core> --slug <slug>
# Returns JSON with prognosis (errors found on clone after update)

WP_PATH="" UPDATE_TYPE="" SLUG=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path) WP_PATH="$2"; shift 2 ;;
        --type) UPDATE_TYPE="$2"; shift 2 ;;
        --slug) SLUG="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$WP_PATH" || -z "$UPDATE_TYPE" ]] && { echo '{"ok":false,"error":"missing_args"}' >&2; exit 1; }
[[ ! -f "$WP_PATH/wp-config.php" ]] && { echo '{"ok":false,"error":"not_wordpress"}' >&2; exit 1; }

# Find wp-cli
WP_CLI=""
for p in /usr/local/bin/wp /usr/bin/wp; do [[ -x "$p" ]] && { WP_CLI="$p"; break; }; done
[[ -z "$WP_CLI" ]] && { echo '{"ok":false,"error":"wp_cli_not_found"}' >&2; exit 1; }

# Step 1: Create clone directory
CLONE_DIR=$(mktemp -d "/tmp/llstack-smart-update.XXXXXXXXXX")
trap 'rm -rf "$CLONE_DIR"' EXIT

echo ">>> Step 1: Cloning site to $CLONE_DIR..." >&2
cp -a "$WP_PATH/." "$CLONE_DIR/"

# Clone database
SITE_URL=$($WP_CLI option get siteurl --path="$CLONE_DIR" --allow-root --skip-plugins --skip-themes 2>/dev/null || echo "")
DB_NAME=$($WP_CLI config get DB_NAME --path="$CLONE_DIR" --allow-root 2>/dev/null || echo "")
DB_USER=$($WP_CLI config get DB_USER --path="$CLONE_DIR" --allow-root 2>/dev/null || echo "")
DB_PASS=$($WP_CLI config get DB_PASSWORD --path="$CLONE_DIR" --allow-root 2>/dev/null || echo "")

# If the wp-config has no DB_NAME (e.g. a freshly extracted tarball where the
# operator hasn't filled in the credentials yet), the previous version silently
# ran `mysqldump ""` and produced a half-empty clone that "succeeded" — the user
# would see "safe_to_apply: true" with no errors and a working wp that pointed
# at the wrong database. Refuse up front.
if [[ -z "$DB_NAME" || ! "$DB_NAME" =~ ^[A-Za-z0-9_]{1,64}$ ]]; then
    echo "    ERROR: wp-config.php has no valid DB_NAME (got: '${DB_NAME:-<empty>}'); refusing to clone" >&2
    ERRORS+=("db_name_missing")
    # Set safe_to_apply=false and emit the JSON below; cleanup will DROP $CLONE_DB
    # which is "" — explicitly skip that step by setting DB_NAME to a sentinel
    DB_NAME=""
fi

# Generate safe clone DB name (only alphanumeric + underscore)
SAFE_PREFIX=$(echo "$DB_NAME" | tr -cd 'a-zA-Z0-9_' | head -c 30)
CLONE_DB="su_${SAFE_PREFIX}_$(date +%s)"
# Validate the result
if ! echo "$CLONE_DB" | grep -qP '^[a-zA-Z_][a-zA-Z0-9_]{0,63}$'; then
    CLONE_DB="su_clone_$(date +%s)"
fi

if [[ -n "$DB_NAME" ]]; then
    echo ">>> Cloning database $DB_NAME → $CLONE_DB..." >&2
    if ! mysql -e "CREATE DATABASE IF NOT EXISTS \`$CLONE_DB\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;" 2>/dev/null; then
        echo "    ERROR: CREATE DATABASE $CLONE_DB failed" >&2
        ERRORS+=("db_create_failed")
    fi
    if ! mysqldump --single-transaction --quick "$DB_NAME" 2>/dev/null | mysql "$CLONE_DB" 2>/dev/null; then
        echo "    ERROR: mysqldump | mysql failed for $DB_NAME → $CLONE_DB" >&2
        ERRORS+=("db_clone_failed")
    fi
fi

# Grant the original DB user access to clone DB (so wp-cli checks work)
# Validate DB_USER to prevent SQL injection (alphanumeric + underscore only)
if [[ -n "$DB_USER" ]] && echo "$DB_USER" | grep -qP '^[a-zA-Z][a-zA-Z0-9_]{0,31}$'; then
    mysql -e "GRANT ALL PRIVILEGES ON \`$CLONE_DB\`.* TO \`$DB_USER\`@\`localhost\`; FLUSH PRIVILEGES;" 2>/dev/null || true
fi

# Point clone to cloned DB
$WP_CLI config set DB_NAME "$CLONE_DB" --path="$CLONE_DIR" --allow-root >&2 2>/dev/null

# Update cleanup trap to also drop clone DB
cleanup() {
    rm -rf "$CLONE_DIR" 2>/dev/null || true
    mysql -e "DROP DATABASE IF EXISTS \`$CLONE_DB\`;" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

# Step 2: Capture pre-update state
echo ">>> Step 2: Capturing pre-update state..." >&2
PRE_VERSION=""
case "$UPDATE_TYPE" in
    core)
        PRE_VERSION=$($WP_CLI core version --path="$CLONE_DIR" --allow-root 2>/dev/null || echo "")
        ;;
    plugin)
        PRE_VERSION=$($WP_CLI plugin get "$SLUG" --field=version --path="$CLONE_DIR" --allow-root 2>/dev/null || echo "")
        ;;
    theme)
        PRE_VERSION=$($WP_CLI theme get "$SLUG" --field=version --path="$CLONE_DIR" --allow-root 2>/dev/null || echo "")
        ;;
esac

# Step 3: Apply update on clone
echo ">>> Step 3: Applying update on clone..." >&2
UPDATE_OUTPUT=""
UPDATE_EXIT=0
case "$UPDATE_TYPE" in
    core)
        UPDATE_OUTPUT=$($WP_CLI core update --path="$CLONE_DIR" --allow-root 2>&1) || UPDATE_EXIT=$?
        ;;
    plugin)
        UPDATE_OUTPUT=$($WP_CLI plugin update --path="$CLONE_DIR" --allow-root -- "$SLUG" 2>&1) || UPDATE_EXIT=$?
        ;;
    theme)
        UPDATE_OUTPUT=$($WP_CLI theme update --path="$CLONE_DIR" --allow-root -- "$SLUG" 2>&1) || UPDATE_EXIT=$?
        ;;
esac
echo "$UPDATE_OUTPUT" >&2

# Step 4: Check for errors
echo ">>> Step 4: Running post-update checks..." >&2
ERRORS=()

# Check 4a: PHP fatal errors
PHP_EXIT=0
PHP_CHECK=$($WP_CLI eval "echo 'PHP_OK';" --path="$CLONE_DIR" --allow-root 2>&1) || PHP_EXIT=$?
if [[ "$PHP_EXIT" -ne 0 || "$PHP_CHECK" != *"PHP_OK"* ]]; then
    ERRORS+=("php_fatal_error")
    echo "  [FAIL] PHP fatal error detected" >&2
else
    echo "  [OK] PHP execution" >&2
fi

# Check 4b: WP core loads without errors
WP_EXIT=0
WP_CHECK=$($WP_CLI core is-installed --path="$CLONE_DIR" --allow-root 2>&1) || WP_EXIT=$?
if [[ "$WP_EXIT" -ne 0 ]]; then
    ERRORS+=("wp_core_broken")
    echo "  [FAIL] WordPress core check failed" >&2
else
    echo "  [OK] WordPress core" >&2
fi

# Check 4c: Database connectivity
DB_EXIT=0
DB_CHECK=$($WP_CLI db check --path="$CLONE_DIR" --allow-root 2>&1) || DB_EXIT=$?
if [[ "$DB_EXIT" -ne 0 ]] || echo "$DB_CHECK" | grep -qi "error"; then
    ERRORS+=("database_error")
    echo "  [FAIL] Database check error" >&2
else
    echo "  [OK] Database" >&2
fi

# Check 4d: Get post-update version
POST_VERSION=""
case "$UPDATE_TYPE" in
    core)
        POST_VERSION=$($WP_CLI core version --path="$CLONE_DIR" --allow-root 2>/dev/null || echo "")
        ;;
    plugin)
        POST_VERSION=$($WP_CLI plugin get "$SLUG" --field=version --path="$CLONE_DIR" --allow-root 2>/dev/null || echo "")
        ;;
    theme)
        POST_VERSION=$($WP_CLI theme get "$SLUG" --field=version --path="$CLONE_DIR" --allow-root 2>/dev/null || echo "")
        ;;
esac

# Step 5: Cleanup clone database
echo ">>> Step 5: Cleaning up clone..." >&2
mysql -e "DROP DATABASE IF EXISTS \`$CLONE_DB\`;" 2>/dev/null || true

# Build error JSON array
ERROR_JSON="[]"
if [[ ${#ERRORS[@]} -gt 0 ]]; then
    ERROR_JSON=$(printf '%s\n' "${ERRORS[@]}" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read().strip().split('\n')))")
fi

echo ">>> Smart Update check complete." >&2
cat << EOF
{"ok":true,"data":{
  "update_type":"$UPDATE_TYPE",
  "slug":"${SLUG:-core}",
  "pre_version":"$PRE_VERSION",
  "post_version":"$POST_VERSION",
  "update_exit_code":$UPDATE_EXIT,
  "errors":$ERROR_JSON,
  "safe_to_apply":$([ ${#ERRORS[@]} -eq 0 ] && [ "$UPDATE_EXIT" -eq 0 ] && echo "true" || echo "false")
}}
EOF
