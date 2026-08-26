#!/bin/bash
set -euo pipefail

# Import panel configuration from export archive
# Usage: panel-import.sh --input <archive>

INPUT=""
while [[ $# -gt 0 ]]; do case "$1" in --input) INPUT="$2"; shift 2 ;; *) shift ;; esac; done

LLSTACK_DIR="${LLSTACK_DIR:-/opt/llstack}"

if [[ -z "$INPUT" || ! -f "$INPUT" ]]; then
    echo '{"ok":false,"error":"input_required"}' >&2
    exit 1
fi

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo ">>> Importing LLStack configuration..."

cd "$TMPDIR"

# Reject archives containing absolute paths, '..' components, or symlinks
# (path traversal / arbitrary-write defense). These checks run BEFORE extraction.
if tar tvzf "$INPUT" | grep -qE '^l' || \
   tar tzf "$INPUT" | grep -qE '(^\.\./|/\.\./|\.\.$|^/)'; then
    echo '{"ok":false,"error":"path_traversal_detected","message":"Archive contains absolute, parent, or symbolic-link paths"}' >&2
    exit 1
fi
tar --no-same-owner xzf "$INPUT"

# Show export info
if [[ -f export-info.json ]]; then
    echo "  Source: $(python3 -c "import json;d=json.load(open('export-info.json'));print(f'{d.get(\"hostname\")} ({d.get(\"os\")})')")"
fi

# Defense in depth: every entry name we derive a destination path from must be a
# plain hostname/path-safe token (no '/', no glob chars, no empty).
sanitize_name() { echo "$1" | grep -qE '^[a-zA-Z0-9._-]+$'; }

# 1. Database (merge or replace)
if [[ -f data/llstack.db ]]; then
    echo "  Importing database..."
    cp data/llstack.db "$LLSTACK_DIR/data/llstack.db"
    cp data/.llstack_* "$LLSTACK_DIR/data/" 2>/dev/null || true
fi

# 2. Vhost configs
if [[ -d vhosts ]]; then
    echo "  Importing vhost configs..."
    for vdir in vhosts/*/; do
        domain=$(basename "$vdir")
        sanitize_name "$domain" || { echo '{"ok":false,"error":"invalid_vhost_dir","message":"Unsafe directory name in archive"}' >&2; exit 1; }
        DEST="/usr/local/lsws/conf/vhosts/$domain"
        mkdir -p "$DEST"
        cp "$vdir/vhconf.conf" "$DEST/" 2>/dev/null || true
    done
fi

# 3. SSL certs
if [[ -d ssl ]]; then
    echo "  Importing SSL certificates..."
    for sdir in ssl/*/; do
        domain=$(basename "$sdir")
        sanitize_name "$domain" || { echo '{"ok":false,"error":"invalid_ssl_dir","message":"Unsafe directory name in archive"}' >&2; exit 1; }
        DEST="/usr/local/lsws/conf/ssl/$domain"
        mkdir -p "$DEST"
        cp "$sdir"/*.pem "$DEST/" 2>/dev/null || true
    done
fi

# 4. httpd_config.conf
if [[ -f httpd_config.conf ]]; then
    echo "  Importing LiteHttpd config..."
    cp httpd_config.conf /usr/local/lsws/conf/httpd_config.conf
fi

# 5. .htaccess files
if [[ -d htaccess ]]; then
    echo "  Importing .htaccess files..."
    for ht in htaccess/*.htaccess; do
        domain=$(basename "$ht" .htaccess)
        # Empty or globbing domain would overwrite every site's .htaccess
        [[ -z "$domain" || "$domain" == "*" ]] && { echo '{"ok":false,"error":"invalid_htaccess_file","message":"Unsafe .htaccess filename in archive"}' >&2; exit 1; }
        sanitize_name "$domain" || { echo '{"ok":false,"error":"invalid_htaccess_file","message":"Unsafe .htaccess filename in archive"}' >&2; exit 1; }
        # Find the site's docroot
        for docroot in /home/*/public_html/"$domain"; do
            if [[ -d "$docroot" ]]; then
                cp "$ht" "$docroot/.htaccess"
                break
            fi
        done
    done
fi

# 6. PHP configs
if [[ -d php ]]; then
    echo "  Importing PHP configs..."
    for ini in php/php*.ini; do
        ver=$(basename "$ini" .ini | sed 's/php//')
        # Validate version is purely numeric (prevent path traversal to /etc/opt/remi/...)
        [[ "$ver" =~ ^[0-9]+$ ]] || { echo '{"ok":false,"error":"invalid_php_file","message":"Unsafe PHP config filename in archive"}' >&2; exit 1; }
        DEST="/etc/opt/remi/php${ver}/php.ini"
        if [[ -f "$DEST" ]]; then
            cp "$ini" "$DEST"
        fi
    done
fi

# 7. Reload services
echo ">>> Reloading services..."
/usr/local/lsws/bin/lswsctrl reload 2>/dev/null || true
systemctl restart llstack 2>/dev/null || true

echo ">>> Import complete!"
echo '{"ok":true}'
