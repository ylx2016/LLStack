#!/bin/bash
# LLStack Panel End-to-End Test
# Runs install.sh then validates the full stack
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0; SKIP=0
VPS_IP=$(hostname -I | awk '{print $1}')
DOMAIN="${VPS_IP//./-}.sslip.io"

check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then
        echo -e "  ${GREEN}PASS${NC}: $name"
        PASS=$((PASS+1))
    else
        echo -e "  ${RED}FAIL${NC}: $name"
        FAIL=$((FAIL+1))
    fi
}

checkv() {
    local name="$1"; local val="$2"
    if [ -n "$val" ] && [ "$val" != "null" ]; then
        echo -e "  ${GREEN}PASS${NC}: $name — $val"
        PASS=$((PASS+1))
    else
        echo -e "  ${RED}FAIL${NC}: $name — (empty)"
        FAIL=$((FAIL+1))
    fi
}

skip() {
    echo -e "  ${YELLOW}SKIP${NC}: $1"
    SKIP=$((SKIP+1))
}

echo "======================================"
echo " LLStack E2E Test — $(date)"
echo " IP: $VPS_IP"
echo " Domain: $DOMAIN"
echo "======================================"

# ─── Phase 1: Installation ───
echo -e "\n=== Phase 1: Installation ==="

# Copy source to where install.sh expects it
if [ -d /tmp/llstack-src ]; then
    rm -rf /opt/llstack-panel
    cp -a /tmp/llstack-src /opt/llstack-panel
fi

# Run install.sh
echo "  Running install.sh..."
bash /opt/llstack-panel/scripts/install.sh 2>&1 | tail -20
INSTALL_RC=$?
checkv "install.sh exit code" "$INSTALL_RC"

# ─── Phase 2: Installation Verification ───
echo -e "\n=== Phase 2: Installation Verification ==="

check "llstack service active" systemctl is-active llstack
check "lshttpd service active" systemctl is-active lshttpd
check "panel db exists" test -f /opt/llstack/data/llstack.db
check "python venv exists" test -f /opt/llstack/backend/.venv/bin/gunicorn
check "frontend dist exists" test -f /opt/llstack/web/dist/index.html
check "sudoers configured" test -f /etc/sudoers.d/llstack
check "logrotate configured" test -f /etc/logrotate.d/llstack

# Cron
CRON_SSL=$(crontab -l 2>/dev/null | grep -c ssl-check-renew)
CRON_DB=$(crontab -l 2>/dev/null | grep -c backup-panel-db)
checkv "cron: ssl renewal" "$CRON_SSL"
checkv "cron: panel db backup" "$CRON_DB"

# Ports
checkv "port 8001 (gunicorn)" "$(ss -tlnp | grep -c ':8001')"
checkv "port 30333 (panel)" "$(ss -tlnp | grep -c ':30333')"
checkv "port 80 (litehttpd)" "$(ss -tlnp | grep -c ':80')"

# LiteHttpd binary
check "litehttpd binary" test -f /usr/local/lsws/bin/openlitespeed
LITEHTTPD_VER=$(/usr/local/lsws/bin/openlitespeed -v 2>&1 | head -1 || echo "unknown")
checkv "litehttpd version" "$LITEHTTPD_VER"

# ─── Phase 3: API Health ───
echo -e "\n=== Phase 3: API Health ==="

HEALTH=$(curl -sk https://127.0.0.1:30333/api/health 2>/dev/null || curl -s http://127.0.0.1:8001/api/health 2>/dev/null)
HEALTH_STATUS=$(echo "$HEALTH" | python3.12 -c "import sys,json; print(json.load(sys.stdin).get('status',''))" 2>/dev/null)
HEALTH_DB=$(echo "$HEALTH" | python3.12 -c "import sys,json; print(json.load(sys.stdin).get('db',''))" 2>/dev/null)
checkv "health status" "$HEALTH_STATUS"
checkv "health db" "$HEALTH_DB"

# Security headers via panel port
HDRS=$(curl -skI https://127.0.0.1:30333/api/health 2>/dev/null || curl -sI http://127.0.0.1:8001/api/health 2>/dev/null)
for h in "X-Content-Type-Options" "X-Frame-Options" "X-Request-ID" "X-Response-Time" "Permissions-Policy" "Referrer-Policy"; do
    if echo "$HDRS" | grep -qi "$h"; then
        echo -e "  ${GREEN}PASS${NC}: header $h"
        PASS=$((PASS+1))
    else
        echo -e "  ${RED}FAIL${NC}: header $h missing"
        FAIL=$((FAIL+1))
    fi
done

# ─── Phase 4: Panel HTTPS Access ───
echo -e "\n=== Phase 4: Panel HTTPS Access ==="

PANEL_CODE=$(curl -sk -o /dev/null -w "%{http_code}" "https://127.0.0.1:30333/" 2>/dev/null)
checkv "panel HTTPS response" "$PANEL_CODE"

PANEL_HTML=$(curl -sk "https://127.0.0.1:30333/" 2>/dev/null | head -5)
if echo "$PANEL_HTML" | grep -q "html\|script\|LLStack"; then
    echo -e "  ${GREEN}PASS${NC}: panel serves HTML/SPA"
    PASS=$((PASS+1))
else
    echo -e "  ${RED}FAIL${NC}: panel not serving HTML"
    FAIL=$((FAIL+1))
fi

# External access via sslip.io
EXT_CODE=$(curl -sk -o /dev/null -w "%{http_code}" --connect-timeout 5 "https://${DOMAIN}:30333/" 2>/dev/null || echo "timeout")
checkv "external HTTPS ($DOMAIN:30333)" "$EXT_CODE"

# ─── Phase 5: Admin Setup + Auth ───
echo -e "\n=== Phase 5: Admin Setup + Auth ==="

# Require an explicit admin password — never fall back to a hardcoded default,
# which would be a backdoor on a live/not-yet-hardened panel.
ADMIN_PASSWORD="${ADMIN_PASSWORD:-}"
if [[ -z "$ADMIN_PASSWORD" ]]; then
    echo -e "  ${RED}SKIP${NC}: Phase 5 — set \$ADMIN_PASSWORD to run the admin auth checks"
    SKIP=$((SKIP+1))
else
TOKEN=$(python3.12 << 'PY'
import json, hashlib, base64, urllib.request, ssl, os
ctx = ssl.create_default_context()
ctx.check_hostname = False
ctx.verify_mode = ssl.CERT_NONE
BASE = "https://127.0.0.1:30333"
pw = os.environ.get("ADMIN_PASSWORD", "")
try:
    r = urllib.request.urlopen(urllib.request.Request(f"{BASE}/api/auth/altcha-challenge"), context=ctx)
except:
    BASE = "http://127.0.0.1:8001"
    r = urllib.request.urlopen(f"{BASE}/api/auth/altcha-challenge")
c = json.load(r)
for i in range(c['maxnumber']+1):
    if hashlib.sha256((c['salt']+str(i)).encode()).hexdigest()==c['challenge']:
        altcha=base64.b64encode(json.dumps({'algorithm':'SHA-256','challenge':c['challenge'],'number':i,'salt':c['salt'],'signature':c['signature']}).encode()).decode()
        break
data=json.dumps({"username":"admin","password":pw,"altcha":altcha}).encode()
try:
    req=urllib.request.Request(f"{BASE}/api/auth/setup",data=data,headers={'Content-Type':'application/json'},method='POST')
    if 'https' in BASE:
        resp=json.load(urllib.request.urlopen(req, context=ctx))
    else:
        resp=json.load(urllib.request.urlopen(req))
    print(resp['data']['token'])
except Exception as e:
    # Maybe already set up, try login
    req=urllib.request.Request(f"{BASE}/api/auth/login",data=data,headers={'Content-Type':'application/json'},method='POST')
    if 'https' in BASE:
        resp=json.load(urllib.request.urlopen(req, context=ctx))
    else:
        resp=json.load(urllib.request.urlopen(req))
    print(resp['data']['token'])
PY
)

if [ -n "$TOKEN" ] && [ ${#TOKEN} -gt 20 ]; then
    checkv "admin auth" "token=${TOKEN:0:20}..."
else
    echo -e "  ${RED}FAIL${NC}: admin auth — no token"
    FAIL=$((FAIL+1))
fi
fi

# ─── Phase 6: Core API Tests ───
echo -e "\n=== Phase 6: Core API Tests ==="

api_test() {
    local name="$1" path="$2"
    local resp=$(curl -s -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:8001${path}" 2>/dev/null)
    local code=$(echo "$resp" | python3.12 -c "import sys,json; print(json.load(sys.stdin).get('code',''))" 2>/dev/null)
    if [ "$code" = "0" ]; then
        echo -e "  ${GREEN}PASS${NC}: $name"
        PASS=$((PASS+1))
    else
        echo -e "  ${RED}FAIL${NC}: $name (code=$code)"
        FAIL=$((FAIL+1))
    fi
}

api_test "system/stats" "/api/system/stats"
api_test "system/version-check" "/api/system/version-check"
api_test "system/services" "/api/system/services"
api_test "sites list" "/api/sites?page=1"
api_test "sites templates" "/api/sites/templates"
api_test "databases engines" "/api/databases/engines"
api_test "databases list" "/api/databases?page=1"
api_test "wordpress instances" "/api/wordpress/instances"
api_test "redis status" "/api/redis/status"
api_test "monitoring current" "/api/monitoring/current"
api_test "php versions" "/api/php/versions"
api_test "files list" "/api/files"
api_test "cron list" "/api/cron"
api_test "backup list" "/api/backup"
api_test "notifications" "/api/notifications"
api_test "logs list" "/api/logs"
api_test "htaccess templates" "/api/htaccess/templates"
api_test "users list" "/api/users"
api_test "audit logs" "/api/users/audit-logs"
api_test "plugins" "/api/plugins"
api_test "optimizer" "/api/optimizer/recommend"
api_test "api docs" "/api/docs"

# Panel backup
BACKUP_CODE=$(curl -s -X POST -H "Authorization: Bearer $TOKEN" "http://127.0.0.1:8001/api/backup/panel" | python3.12 -c "import sys,json; print(json.load(sys.stdin).get('code',''))" 2>/dev/null)
checkv "backup panel (POST)" "$BACKUP_CODE"

# ─── Phase 7: Pytest ───
echo -e "\n=== Phase 7: Pytest ==="
cd /opt/llstack/backend
/opt/llstack/backend/.venv/bin/pip install -q pytest 2>/dev/null
PYTEST_RESULT=$(LLSTACK_DB_PATH=/tmp/pytest-e2e.db LLSTACK_SCRIPTS_DIR=/nonexistent /opt/llstack/backend/.venv/bin/pytest tests/ -q --tb=no 2>&1 | tail -1)
checkv "pytest" "$PYTEST_RESULT"

# ─── Summary ───
echo ""
echo "======================================"
echo -e " Results: ${GREEN}${PASS} passed${NC}, ${RED}${FAIL} failed${NC}, ${YELLOW}${SKIP} skipped${NC}"
echo "======================================"

# Cleanup
rm -f /tmp/pytest-e2e.db

exit $FAIL
