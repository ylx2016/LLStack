#!/bin/bash
set -euo pipefail

# Smart SSL auto-renewal: only renew if <15 days left, check www coverage
# Usage: ssl-auto-renew.sh [--dry-run]
# Designed to be called by cron daily

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

SSL_DIR="/usr/local/lsws/conf/ssl"
# Find acme.sh — install.sh installs to /root/.acme.sh; fall back to other common locations.
ACME_HOME="${ACME_HOME:-}"
if [[ -z "$ACME_HOME" ]]; then
    for _p in "/root/.acme.sh" "/opt/llstack/.acme.sh" "$HOME/.acme.sh"; do
        if [[ -f "$_p/acme.sh" ]]; then
            ACME_HOME="$_p"
            break
        fi
    done
fi
RENEWED=0
SKIPPED=0
FAILED=0
RESULTS='['
FIRST=true

for domain_dir in "$SSL_DIR"/*/; do
    [[ ! -d "$domain_dir" ]] && continue
    domain=$(basename "$domain_dir")
    [[ "$domain" == "panel" ]] && continue

    cert_file="$domain_dir/fullchain.pem"
    [[ ! -f "$cert_file" ]] && continue

    # Check expiry
    EXPIRY_DATE=$(openssl x509 -enddate -noout -in "$cert_file" 2>/dev/null | cut -d= -f2)
    if [[ -z "$EXPIRY_DATE" ]]; then
        continue
    fi

    EXPIRY_TS=$(date -d "$EXPIRY_DATE" +%s 2>/dev/null || echo 0)
    NOW_TS=$(date +%s)
    DAYS_LEFT=$(( (EXPIRY_TS - NOW_TS) / 86400 ))

    # Check issuer (skip staging certs — always renew)
    ISSUER=$(openssl x509 -issuer -noout -in "$cert_file" 2>/dev/null || echo "")
    IS_STAGING=false
    if echo "$ISSUER" | grep -qi "staging"; then
        IS_STAGING=true
    fi

    # Check if www subdomain is covered
    COVERED_DOMAINS=$(openssl x509 -text -noout -in "$cert_file" 2>/dev/null | grep "DNS:" | tr ',' '\n' | sed 's/.*DNS://g' | tr -d ' ')
    HAS_WWW=false
    if echo "$COVERED_DOMAINS" | grep -q "www\.$domain"; then
        HAS_WWW=true
    fi

    # Decision: renew if <15 days left, or staging, or missing www
    REASON=""
    if [[ "$IS_STAGING" == true ]]; then
        REASON="staging_cert"
    elif [[ "$DAYS_LEFT" -lt 15 ]]; then
        REASON="expiring_in_${DAYS_LEFT}_days"
    elif [[ "$HAS_WWW" == false ]]; then
        REASON="missing_www_coverage"
    fi

    if [[ -z "$REASON" ]]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Add to results
    [[ "$FIRST" == true ]] && FIRST=false || RESULTS+=','

    if [[ "$DRY_RUN" == true ]]; then
        RESULTS+="{\"domain\":\"$domain\",\"days_left\":$DAYS_LEFT,\"reason\":\"$REASON\",\"action\":\"would_renew\"}"
        continue
    fi

    # Renew via acme.sh
    echo ">>> Renewing $domain (reason: $REASON, days_left: $DAYS_LEFT)..."

    # Find webroot
    WEBROOT=""
    VHCONF="/usr/local/lsws/conf/vhosts/$domain/vhconf.conf"
    if [[ -f "$VHCONF" ]]; then
        WEBROOT=$(grep 'docRoot' "$VHCONF" | awk '{print $2}' | head -1)
    fi
    [[ -z "$WEBROOT" ]] && WEBROOT="/opt/llstack/web/dist"

    RENEW_OK=false
    if [[ -x "$ACME_HOME/acme.sh" ]]; then
        if "$ACME_HOME/acme.sh" --renew -d "$domain" --ecc --force 2>&1; then
            # Install cert — treat failure as renewal failure
            if "$ACME_HOME/acme.sh" --install-cert -d "$domain" --ecc \
                --key-file "$SSL_DIR/$domain/privkey.pem" \
                --fullchain-file "$SSL_DIR/$domain/fullchain.pem" \
                --reloadcmd "/usr/local/lsws/bin/lswsctrl reload" 2>&1; then
                RENEW_OK=true
            else
                echo "  WARNING: cert renewed but install-cert failed for $domain"
            fi
        fi
    fi

    if [[ "$RENEW_OK" == true ]]; then
        RENEWED=$((RENEWED + 1))
        RESULTS+="{\"domain\":\"$domain\",\"days_left\":$DAYS_LEFT,\"reason\":\"$REASON\",\"action\":\"renewed\"}"
    else
        FAILED=$((FAILED + 1))
        RESULTS+="{\"domain\":\"$domain\",\"days_left\":$DAYS_LEFT,\"reason\":\"$REASON\",\"action\":\"failed\"}"
    fi
done

RESULTS+=']'

cat << EOF
{"ok":true,"data":{"renewed":$RENEWED,"skipped":$SKIPPED,"failed":$FAILED,"details":$RESULTS}}
EOF
