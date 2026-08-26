#!/bin/bash
set -euo pipefail

# Check all SSL certificates and renew those expiring within 30 days
# Usage: ssl-check-renew.sh
# Designed to be run via cron: 0 3 * * * /opt/llstack/scripts/ssl/ssl-check-renew.sh

ACME_HOME="${ACME_HOME:-/root/.acme.sh}"
CERT_DIR="/usr/local/lsws/conf/ssl"
RENEW_DAYS=30
RENEWED=0

echo ">>> Checking SSL certificates..." >&2

for cert in "$CERT_DIR"/*/fullchain.pem; do
    if [[ ! -f "$cert" ]]; then
        continue
    fi

    domain=$(basename "$(dirname "$cert")")
    if [[ "$domain" == "panel" ]]; then
        continue  # Skip self-signed panel cert
    fi

    # Check expiry
    expiry=$(openssl x509 -enddate -noout -in "$cert" 2>/dev/null | cut -d= -f2)
    if [[ -z "$expiry" ]]; then
        continue
    fi

    expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null || echo 0)
    now_epoch=$(date +%s)
    days_left=$(( (expiry_epoch - now_epoch) / 86400 ))

    if [[ $days_left -lt $RENEW_DAYS ]]; then
        echo "  $domain: $days_left days left — renewing..." >&2
        if [[ -d "$ACME_HOME" && -x "$ACME_HOME/acme.sh" ]]; then
            # Count as renewed only if both renew and install-cert succeed.
            if "$ACME_HOME/acme.sh" --renew -d "$domain" --ecc >&2 2>&1 && \
               "$ACME_HOME/acme.sh" --install-cert -d "$domain" --ecc \
                    --key-file "$CERT_DIR/$domain/privkey.pem" \
                    --fullchain-file "$CERT_DIR/$domain/fullchain.pem" >&2 2>&1; then
                # NOT ((RENEWED++)): with RENEWED=0 the post-increment expression
                # evaluates to 0, which is exit status 1 and aborts under set -e.
                RENEWED=$((RENEWED + 1))
            else
                echo "  $domain: renewal or install failed" >&2
            fi
        else
            echo "  $domain: acme.sh not found at $ACME_HOME, cannot renew" >&2
        fi
    else
        echo "  $domain: $days_left days left — OK" >&2
    fi
done

if [[ $RENEWED -gt 0 ]]; then
    echo ">>> Reloading LiteHttpd ($RENEWED certs renewed)..." >&2
    /usr/local/lsws/bin/lswsctrl reload 2>/dev/null || true
fi

echo ">>> Done. Renewed: $RENEWED" >&2
echo "{\"ok\":true,\"data\":{\"renewed\":$RENEWED}}"
