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
# Collect per-domain results as a bash array; the JSON is built with
# Python at the end so user-controlled values (domain, reason string) cannot
# break the JSON contract.
RESULTS=()
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
    elif [[ "$DAYS_LEFT" -lt 30 ]]; then
        REASON="expiring_in_${DAYS_LEFT}_days"
    elif [[ "$HAS_WWW" == false ]]; then
        REASON="missing_www_coverage"
    fi

    if [[ -z "$REASON" ]]; then
        SKIPPED=$((SKIPPED + 1))
        continue
    fi

    # Add to results
    if [[ "$DRY_RUN" == true ]]; then
        RESULTS+=("$(python3 - "$domain" "$DAYS_LEFT" "$REASON" <<'PYEOF'
import json, sys
d, dl, r = sys.argv[1], int(sys.argv[2]), sys.argv[3]
print(json.dumps({"domain": d, "days_left": dl, "reason": r, "action": "would_renew"}, separators=(",", ":")))
PYEOF
        )")
        continue
    fi

    # Renew via acme.sh
    echo ">>> Renewing $domain (reason: $REASON, days_left: $DAYS_LEFT)..." >&2

    # Find webroot
    WEBROOT=""
    VHCONF="/usr/local/lsws/conf/vhosts/$domain/vhconf.conf"
    if [[ -f "$VHCONF" ]]; then
        WEBROOT=$(grep 'docRoot' "$VHCONF" | awk '{print $2}' | head -1)
    fi
    [[ -z "$WEBROOT" ]] && WEBROOT="/opt/llstack/web/dist"

    RENEW_OK=false
    if [[ -x "$ACME_HOME/acme.sh" ]]; then
        if "$ACME_HOME/acme.sh" --renew -d "$domain" --ecc --force >&2 2>&1; then
            # Install cert — treat failure as renewal failure
            if "$ACME_HOME/acme.sh" --install-cert -d "$domain" --ecc \
                --key-file "$SSL_DIR/$domain/privkey.pem" \
                --fullchain-file "$SSL_DIR/$domain/fullchain.pem" \
                --reloadcmd "/usr/local/lsws/bin/lswsctrl reload" >&2 2>&1; then
                RENEW_OK=true
            else
                echo "  WARNING: cert renewed but install-cert failed for $domain" >&2
            fi
        fi
    fi

    if [[ "$RENEW_OK" == true ]]; then
        RENEWED=$((RENEWED + 1))
        ACTION="renewed"
    else
        FAILED=$((FAILED + 1))
        ACTION="failed"
    fi
    RESULTS+=("$(python3 - "$domain" "$DAYS_LEFT" "$REASON" "$ACTION" <<'PYEOF'
import json, sys
d, dl, r, a = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
print(json.dumps({"domain": d, "days_left": dl, "reason": r, "action": a}, separators=(",", ":")))
PYEOF
    )")
done

# Use Python to serialize the full document. $RESULTS is a bash array
# where each element is a pre-encoded JSON dict (one per domain) — pass
# them as separate args rather than re-parsing a string.
python3 - "$RENEWED" "$SKIPPED" "$FAILED" "${RESULTS[@]}" <<'PYEOF'
import json, sys
renewed, skipped, failed = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
entries = sys.argv[4:]
details = [json.loads(e) for e in entries]
print(json.dumps({
    "ok": True,
    "data": {
        "renewed": renewed,
        "skipped": skipped,
        "failed": failed,
        "details": details,
    },
}, separators=(",", ":")))
PYEOF
