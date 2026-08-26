#!/bin/bash
set -euo pipefail

# Generic application installer driven by JSON manifests
# Usage: app-install.sh --app-id <id> --doc-root <path> --domain <domain> \
#        [--admin-email <email>] [--db-name <name>] [--db-user <user>] [--db-pass-file <path>] \
#        [--admin-pw-file <path>]
#
# Progress goes to stderr; stdout carries only the final JSON document.

APP_ID="" DOC_ROOT="" DOMAIN="" ADMIN_EMAIL="" DB_NAME="" DB_USER="" DB_PASS_FILE="" ADMIN_PW_FILE=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app-id)         APP_ID="$2"; shift 2 ;;
        --doc-root)       DOC_ROOT="$2"; shift 2 ;;
        --domain)         DOMAIN="$2"; shift 2 ;;
        --admin-email)    ADMIN_EMAIL="$2"; shift 2 ;;
        --db-name)        DB_NAME="$2"; shift 2 ;;
        --db-user)        DB_USER="$2"; shift 2 ;;
        --db-pass-file)   DB_PASS_FILE="$2"; shift 2 ;;
        --admin-pw-file)  ADMIN_PW_FILE="$2"; shift 2 ;;
        # Legacy compat: accept --manifest but resolve to app-id
        --manifest)       APP_ID=$(basename "$2" .json); shift 2 ;;
        *) echo '{"ok":false,"error":"unknown_arg"}' >&2; exit 1 ;;
    esac
done

[[ -z "$APP_ID" || -z "$DOC_ROOT" || -z "$DOMAIN" ]] && {
    echo '{"ok":false,"error":"missing_args"}' >&2; exit 1
}

# Validate app-id (prevent path traversal)
if ! echo "$APP_ID" | grep -qP '^[a-z][a-z0-9-]{0,30}$'; then
    echo '{"ok":false,"error":"invalid_app_id"}' >&2; exit 1
fi
[[ ! -d "$DOC_ROOT" ]] && { echo '{"ok":false,"error":"doc_root_not_found"}' >&2; exit 1; }

# Resolve manifest from trusted directories only
MANIFEST=""
for dir in "${LLSTACK_SCRIPTS_DIR:-/opt/llstack/scripts}/app/manifests" \
           "$(cd "$(dirname "$0")" && pwd)/manifests"; do
    candidate="$dir/$APP_ID.json"
    if [[ -f "$candidate" ]]; then
        # Actually enforce what the old comment only claimed: the manifest drives
        # commands run as root, so it must be root-owned and not writable by
        # group/other (the service account must not be able to rewrite it).
        perms=$(stat -c '%U %a' "$candidate" 2>/dev/null || echo "")
        owner=${perms%% *}
        mode=${perms##* }
        if [[ "$owner" != "root" ]]; then
            echo '{"ok":false,"error":"manifest_not_root_owned","message":"'"$candidate"' must be owned by root"}' >&2
            exit 1
        fi
        if [[ $(( 8#${mode:-777} & 8#022 )) -ne 0 ]]; then
            echo '{"ok":false,"error":"manifest_writable","message":"'"$candidate"' must not be group/world writable"}' >&2
            exit 1
        fi
        MANIFEST="$candidate"
        break
    fi
done

[[ -z "$MANIFEST" ]] && { echo '{"ok":false,"error":"manifest_not_found"}' >&2; exit 1; }

# Cleanup trap for password files and the private work dir
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"; rm -f -- "$ADMIN_PW_FILE" "$DB_PASS_FILE" 2>/dev/null || true' EXIT

# Parse the manifest field-by-field over a NUL-separated stream. Reading a single
# space-joined line would fold consecutive separators when a field is absent and
# shift every subsequent value (that silently broke the Laravel manifest, whose
# download_url and extract_dir are unset).
mapfile -d '' -t FIELDS < <(python3 - "$MANIFEST" <<'PYEOF'
import json, sys
m = json.load(open(sys.argv[1]))
vals = [
    str(m.get('name', 'Unknown')),
    str(m.get('download_url', '')),
    str(m.get('extract_dir', '')),
    str(m.get('install_method', 'download')),
    str(m.get('composer_command', '')),
    str(m.get('sha256', '')),
]
sys.stdout.write('\0'.join(vals))
PYEOF
)
APP_NAME="${FIELDS[0]:-Unknown}"
DOWNLOAD_URL="${FIELDS[1]:-}"
EXTRACT_DIR="${FIELDS[2]:-}"
INSTALL_METHOD="${FIELDS[3]:-download}"
COMPOSER_CMD="${FIELDS[4]:-}"
EXPECT_SHA="${FIELDS[5]:-}"

# Read DB password
DB_PASS=""
[[ -n "$DB_PASS_FILE" && -f "$DB_PASS_FILE" ]] && DB_PASS=$(cat "$DB_PASS_FILE")

URL="https://$DOMAIN"
SITE_USER=$(stat -c '%U' "$DOC_ROOT" 2>/dev/null || echo root)

echo ">>> Installing $APP_NAME to $DOC_ROOT..." >&2

# ── Step 1: fetch the application ──
if [[ "$INSTALL_METHOD" == "composer" ]]; then
    if [[ -z "$COMPOSER_CMD" ]]; then
        echo '{"ok":false,"error":"manifest_missing_composer_command"}' >&2; exit 1
    fi
    if ! command -v composer &>/dev/null; then
        echo '{"ok":false,"error":"composer_not_found","message":"Install composer first"}' >&2; exit 1
    fi
    # Only allow `composer create-project <pkg> <dir>` and run it as the site user,
    # never as root.
    read -ra CMD_PARTS <<< "$COMPOSER_CMD"
    if [[ "${CMD_PARTS[0]:-}" != "composer" || "${CMD_PARTS[1]:-}" != "create-project" ]]; then
        echo '{"ok":false,"error":"unsupported_composer_command"}' >&2; exit 1
    fi
    PKG="${CMD_PARTS[2]:-}"
    if [[ -z "$PKG" ]]; then
        echo '{"ok":false,"error":"unsupported_composer_command"}' >&2; exit 1
    fi
    echo ">>> Using Composer ($PKG)..." >&2
    # create-project refuses a non-empty target, and site-create.sh seeds the doc
    # root with index.html/.htaccess — build in a staging dir and move the result.
    if ! sudo -u "$SITE_USER" composer create-project --no-interaction "$PKG" "$WORK/app" >&2 2>&1; then
        echo '{"ok":false,"error":"composer_failed"}' >&2; exit 1
    fi
    shopt -s dotglob
    cp -a "$WORK/app/." "$DOC_ROOT/"
    shopt -u dotglob
elif [[ -n "$DOWNLOAD_URL" ]]; then
    echo ">>> Downloading from $DOWNLOAD_URL..." >&2
    # -f so an HTTP error page is never mistaken for a package payload
    if ! curl -fsSL --retry 3 --max-time 300 "$DOWNLOAD_URL" -o "$WORK/pkg"; then
        echo '{"ok":false,"error":"download_failed"}' >&2; exit 1
    fi
    if [[ -n "$EXPECT_SHA" ]]; then
        ACTUAL_SHA=$(sha256sum "$WORK/pkg" | awk '{print $1}')
        if [[ "$ACTUAL_SHA" != "$EXPECT_SHA" ]]; then
            echo '{"ok":false,"error":"checksum_mismatch"}' >&2; exit 1
        fi
    fi

    mkdir -p "$WORK/extract"
    if [[ "$DOWNLOAD_URL" == *.zip ]]; then
        if ! unzip -qo "$WORK/pkg" -d "$WORK/extract" >&2 2>&1; then
            echo '{"ok":false,"error":"extract_failed"}' >&2; exit 1
        fi
    else
        if ! tar xzf "$WORK/pkg" -C "$WORK/extract" >&2 2>&1; then
            echo '{"ok":false,"error":"extract_failed"}' >&2; exit 1
        fi
    fi

    # Locate the application root. Prefer the manifest's extract_dir, but fall back
    # to detecting a single wrapper directory — `cp -a extract/*/*` would flatten
    # the tree and drop top-level files like index.php.
    shopt -s dotglob nullglob
    SRC="$WORK/extract"
    if [[ -n "$EXTRACT_DIR" && -d "$SRC/$EXTRACT_DIR" ]]; then
        SRC="$SRC/$EXTRACT_DIR"
    elif [[ ! -f "$SRC/index.php" ]]; then
        entries=("$SRC"/*)
        if [[ ${#entries[@]} -eq 1 && -d "${entries[0]}" ]]; then
            SRC="${entries[0]}"
        elif [[ -d "$SRC/build" ]]; then
            SRC="$SRC/build"
        fi
    fi
    if [[ -z "$(echo "$SRC"/*)" ]]; then
        shopt -u dotglob nullglob
        echo '{"ok":false,"error":"empty_archive"}' >&2; exit 1
    fi
    cp -a "$SRC/." "$DOC_ROOT/"
    shopt -u dotglob nullglob
else
    echo '{"ok":false,"error":"manifest_has_no_source","message":"Neither composer_command nor download_url is set"}' >&2
    exit 1
fi

# ── Step 2: app-specific setup ──
if [[ "$APP_ID" == "wordpress" ]]; then
    WP_CLI=""
    for p in /usr/local/bin/wp /usr/bin/wp; do [[ -x "$p" ]] && { WP_CLI="$p"; break; }; done

    if [[ -z "$WP_CLI" ]]; then
        # Don't silently skip config+install and still report success — the user
        # would get bare files with no wp-config.php and no way forward.
        echo '{"ok":false,"error":"wp_cli_not_found","message":"Install wp-cli: curl -O https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar && chmod +x wp-cli.phar && mv wp-cli.phar /usr/local/bin/wp"}' >&2
        exit 1
    fi
    if [[ -n "$DB_NAME" ]]; then
        echo ">>> Configuring WordPress..." >&2
        if ! $WP_CLI config create --path="$DOC_ROOT" --dbname="$DB_NAME" --dbuser="$DB_USER" \
                --dbhost="localhost" --allow-root --skip-check --prompt=dbpass <<< "$DB_PASS" >&2 2>&1; then
            echo '{"ok":false,"error":"wp_config_failed"}' >&2; exit 1
        fi
        chmod 640 "$DOC_ROOT/wp-config.php" 2>/dev/null || true

        if [[ -n "$ADMIN_PW_FILE" && -f "$ADMIN_PW_FILE" ]]; then
            echo ">>> Installing WordPress..." >&2
            if ! $WP_CLI core install --path="$DOC_ROOT" --url="$URL" --title="$APP_NAME Site" \
                    --admin_user="admin" --admin_email="$ADMIN_EMAIL" --allow-root --skip-email \
                    --prompt=admin_password < "$ADMIN_PW_FILE" >&2 2>&1; then
                echo '{"ok":false,"error":"wp_install_failed"}' >&2; exit 1
            fi
        fi

        echo ">>> Installing LiteSpeed Cache plugin..." >&2
        $WP_CLI plugin install litespeed-cache --activate --path="$DOC_ROOT" --allow-root >&2 2>&1 || true
    fi
elif [[ "$APP_ID" == "laravel" ]]; then
    echo ">>> Running Laravel setup..." >&2
    ( cd "$DOC_ROOT" && sudo -u "$SITE_USER" php artisan key:generate --force >&2 2>&1 ) || true
fi

# ── Step 3: ownership ──
chown -R "$SITE_USER:$SITE_USER" "$DOC_ROOT" 2>/dev/null || true

echo ">>> $APP_NAME installation complete!" >&2
printf '{"ok":true,"data":{"app":"%s","name":"%s","path":"%s"}}\n' "$APP_ID" "$APP_NAME" "$DOC_ROOT"
