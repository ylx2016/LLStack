#!/bin/bash
set -euo pipefail

# Install WordPress via wp-cli
# Usage: wp-install.sh --path <doc_root> --url <site_url> --title <title> \
#        --admin-user <user> --admin-email <email> --admin-pass-file <path> \
#        [--db-name <name> --db-user <user> --db-pass-file <path>] [--locale <locale>]

PATH_ARG="" URL="" TITLE="" ADMIN_USER="" ADMIN_EMAIL="" ADMIN_PASS_FILE=""
DB_NAME="" DB_USER="" DB_PASS_FILE="" LOCALE="en_US" DB_HOST="localhost"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --path)            PATH_ARG="$2"; shift 2 ;;
        --url)             URL="$2"; shift 2 ;;
        --title)           TITLE="$2"; shift 2 ;;
        --admin-user)      ADMIN_USER="$2"; shift 2 ;;
        --admin-email)     ADMIN_EMAIL="$2"; shift 2 ;;
        --admin-pass-file) ADMIN_PASS_FILE="$2"; shift 2 ;;
        --db-name)         DB_NAME="$2"; shift 2 ;;
        --db-user)         DB_USER="$2"; shift 2 ;;
        --db-pass-file)    DB_PASS_FILE="$2"; shift 2 ;;
        --db-host)         DB_HOST="$2"; shift 2 ;;
        --locale)          LOCALE="$2"; shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$PATH_ARG" || -z "$URL" || -z "$TITLE" || -z "$ADMIN_USER" || -z "$ADMIN_EMAIL" ]] && {
    echo '{"ok":false,"error":"missing_args"}' >&2; exit 1
}

# Find wp-cli
WP_CLI=""
for p in /usr/local/bin/wp /usr/bin/wp; do
    [[ -x "$p" ]] && { WP_CLI="$p"; break; }
done
[[ -z "$WP_CLI" ]] && { echo '{"ok":false,"error":"wp_cli_not_found","message":"Install wp-cli: curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp"}' >&2; exit 1; }

# Read passwords from files
ADMIN_PASS=""
if [[ -n "$ADMIN_PASS_FILE" && -f "$ADMIN_PASS_FILE" ]]; then
    ADMIN_PASS=$(cat "$ADMIN_PASS_FILE")
    rm -f "$ADMIN_PASS_FILE"
fi
[[ -z "$ADMIN_PASS" ]] && ADMIN_PASS=$(openssl rand -base64 16)

DB_PASS=""
if [[ -n "$DB_PASS_FILE" && -f "$DB_PASS_FILE" ]]; then
    DB_PASS=$(cat "$DB_PASS_FILE")
    rm -f "$DB_PASS_FILE"
fi

# Ensure directory exists
mkdir -p "$PATH_ARG"

echo ">>> Downloading WordPress..." >&2
$WP_CLI core download --path="$PATH_ARG" --locale="$LOCALE" --allow-root 2>&1 || true

# Generate wp-config.php if DB info provided
if [[ -n "$DB_NAME" && -n "$DB_USER" ]]; then
    echo ">>> Configuring wp-config.php..." >&2
    # Write DB password via prompt stdin to avoid /proc exposure
    $WP_CLI config create \
        --path="$PATH_ARG" \
        --dbname="$DB_NAME" \
        --dbuser="$DB_USER" \
        --dbhost="$DB_HOST" \
        --allow-root \
        --skip-check \
        --prompt=dbpass <<< "$DB_PASS" >&2 2>&1
fi

echo ">>> Installing WordPress..." >&2
# Write admin password via temp file to avoid /proc exposure
ADMIN_PW_TMP=$(mktemp /tmp/.wp_admin_pw.XXXXXXXXXX)
chmod 600 "$ADMIN_PW_TMP"
echo "$ADMIN_PASS" > "$ADMIN_PW_TMP"
$WP_CLI core install \
    --path="$PATH_ARG" \
    --url="$URL" \
    --title="$TITLE" \
    --admin_user="$ADMIN_USER" \
    --admin_email="$ADMIN_EMAIL" \
    --allow-root \
    --skip-email \
    --prompt=admin_password < "$ADMIN_PW_TMP" >&2 2>&1
rm -f "$ADMIN_PW_TMP"

# Get installed version
VERSION=$($WP_CLI core version --path="$PATH_ARG" --allow-root 2>/dev/null || echo "unknown")

# Set ownership to the site user
SITE_USER=$(stat -c '%U' "$(dirname "$PATH_ARG")" 2>/dev/null || echo "root")
chown -R "$SITE_USER:$SITE_USER" "$PATH_ARG" 2>/dev/null || true

echo ">>> WordPress installed successfully!" >&2
# Use Python for JSON serialization — $PATH_ARG, $URL, $VERSION, $ADMIN_USER
# are all user-controlled and could contain " or \.
python3 - "$PATH_ARG" "$URL" "$VERSION" "$ADMIN_USER" <<'PYEOF'
import json, sys
path, url, version, admin_user = sys.argv[1:5]
print(json.dumps({
    "ok": True,
    "data": {
        "path": path,
        "url": url,
        "version": version,
        "admin_user": admin_user,
    },
}, separators=(",", ":")))
PYEOF
