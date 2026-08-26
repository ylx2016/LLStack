#!/bin/bash
set -euo pipefail

# Issue Let's Encrypt SSL certificate via acme.sh
# Usage: ssl-issue.sh --domain <domain> [--webroot <path>]

DOMAIN=""
WEBROOT=""
# Find acme.sh — installed by install.sh, may be in /root or /opt/llstack
ACME_HOME=""
for p in "/root/.acme.sh" "/opt/llstack/.acme.sh" "$HOME/.acme.sh"; do
    [[ -f "$p/acme.sh" ]] && { ACME_HOME="$p"; break; }
done
[[ -z "$ACME_HOME" ]] && { echo '{"ok":false,"error":"acme_not_installed"}' >&2; exit 1; }
CERT_DIR="/usr/local/lsws/conf/ssl"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)  DOMAIN="$2"; shift 2 ;;
        --webroot) WEBROOT="$2"; shift 2 ;;
        *) echo '{"ok": false, "error": "unknown_arg"}' >&2; exit 1 ;;
    esac
done

if [[ -z "$DOMAIN" ]]; then
    echo '{"ok": false, "error": "missing_args"}' >&2
    exit 1
fi

# Validate domain format
if ! echo "$DOMAIN" | grep -qP '^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
    echo '{"ok": false, "error": "invalid_domain"}' >&2
    exit 1
fi

# Find webroot from vhost config if not specified
if [[ -z "$WEBROOT" ]]; then
    VHCONF="/usr/local/lsws/conf/vhosts/$DOMAIN/vhconf.conf"
    if [[ -f "$VHCONF" ]]; then
        WEBROOT=$(grep 'docRoot' "$VHCONF" | awk '{print $2}' | head -1)
    fi
fi

if [[ -z "$WEBROOT" || ! -d "$WEBROOT" ]]; then
    # Fallback: search common doc_root locations
    for d in "/opt/llstack/public_html/$DOMAIN" "/var/www/public_html/$DOMAIN" "/home"/*/public_html/"$DOMAIN"; do
        [[ -d "$d" ]] && { WEBROOT="$d"; break; }
    done
fi

if [[ -z "$WEBROOT" || ! -d "$WEBROOT" ]]; then
    echo '{"ok": false, "error": "webroot_not_found"}' >&2
    exit 1
fi

# Ensure .well-known directory exists for ACME challenge
mkdir -p "$WEBROOT/.well-known/acme-challenge"
chmod -R 755 "$WEBROOT/.well-known"
chown -R nobody:nobody "$WEBROOT/.well-known" 2>/dev/null || true

echo ">>> Setting up webroot..." >&2
mkdir -p "$CERT_DIR/$DOMAIN"

# Issue certificate. acme.sh v3+ uses ZeroSSL as the default CA, which
# requires a registered email before any cert can be issued. We're not
# asking the user for an email — pin Let's Encrypt instead, which still
# works with no registration for HTTP-01 challenges.
echo ">>> Issuing certificate for $DOMAIN..." >&2
if ! "$ACME_HOME/acme.sh" --issue \
    -d "$DOMAIN" \
    -w "$WEBROOT" \
    --keylength ec-256 \
    --server letsencrypt >&2 2>&1; then
    # Check if cert already exists (acme.sh returns non-zero for "already issued")
    if [[ ! -f "$CERT_DIR/$DOMAIN/fullchain.pem" ]]; then
        echo '{"ok": false, "error": "cert_issue_failed", "message": "acme.sh --issue failed"}' >&2
        exit 1
    fi
fi

# Install certificate to LiteHttpd
if ! "$ACME_HOME/acme.sh" --install-cert -d "$DOMAIN" --ecc \
    --key-file "$CERT_DIR/$DOMAIN/privkey.pem" \
    --fullchain-file "$CERT_DIR/$DOMAIN/fullchain.pem" \
    --reloadcmd "/usr/local/lsws/bin/lswsctrl reload" \
    >&2 2>&1; then
    echo '{"ok": false, "error": "cert_install_failed", "message": "acme.sh --install-cert failed"}' >&2
    exit 1
fi

# Verify files exist
if [[ -f "$CERT_DIR/$DOMAIN/fullchain.pem" && -f "$CERT_DIR/$DOMAIN/privkey.pem" ]]; then
    # Get expiry
    EXPIRY=$(openssl x509 -enddate -noout -in "$CERT_DIR/$DOMAIN/fullchain.pem" 2>/dev/null | cut -d= -f2)
    echo "{\"ok\": true, \"data\": {\"domain\": \"$DOMAIN\", \"cert_path\": \"$CERT_DIR/$DOMAIN/fullchain.pem\", \"key_path\": \"$CERT_DIR/$DOMAIN/privkey.pem\", \"expiry\": \"$EXPIRY\"}}"
else
    echo '{"ok": false, "error": "cert_issue_failed"}' >&2
    exit 1
fi
