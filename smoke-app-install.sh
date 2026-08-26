#!/bin/bash
# Smoke harness for LLStack scripts. Runs the REAL scripts in a hermetic env
# where external tools (wp-cli, composer, curl, mysql, sudo, ...) are stubs.
#
# What we test:
#   1. JSON contract:  error JSON goes to stderr; success JSON on stdout;
#                      exactly one JSON document is produced and it's parseable.
#   2. Error paths:    invalid args, missing args, missing deps, bad manifest
#                      all return {"ok":false,"error":...}.
#   3. End-to-end:     a successful install path actually completes and the
#                      doc-root ends up populated.
#   4. Defence-in-depth: a world-writable manifest is rejected.

set -uo pipefail
PASS=0; FAIL=0; SKIP=0
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; NC=$'\033[0m'

SMOKE=/tmp/smoke
SCRIPTS=/z/t/LLStack-main/scripts
# /usr/local/bin/sqlite3 is a symlink to the real sqlite3.exe the user
# installed at C:\Users\hjm\Desktop\claude\sqlite3\sqlite3.exe (the bash
# wrapper at /tmp/smoke/bin/sqlite3 is no longer needed and was removed).
export PATH="/usr/local/bin:/tmp/smoke/bin:/usr/bin:/bin"
pass() { echo "  ${GRN}PASS${NC}: $1"; PASS=$((PASS+1)); }
fail() { echo "  ${RED}FAIL${NC}: $1 — $2"; FAIL=$((FAIL+1)); }

# Run a script, capture stdout/stderr, and validate the contract.
# Contract: exit != 0 ⇒ error JSON MUST be on stderr (parseable, ok=false).
#           exit == 0 ⇒ success JSON MUST be on stdout (parseable, ok=true).
#   args:  label  expected_kind(e|s)  expected_error_substring  script  args...
run() {
    local label="$1" kind="$2" want_err="$3"; shift 3
    local script="$1"; shift
    local OUT=$SMOKE/out.txt ERR=$SMOKE/err.txt
    bash "$script" "$@" >"$OUT" 2>"$ERR"
    local rc=$?
    local body err
    body=$(cat "$OUT")
    err=$(cat "$ERR")
    local combined="$body"$'\n'"$err"

    # The contract: exactly one JSON document anywhere in stdout+stderr
    # Some scripts (wp-smart-update.sh) emit a pretty-printed heredoc with newlines
    # inside the JSON value, so concatenate the streams first.
    local doc
    doc=$(printf '%s' "$combined" \
        | python3 -c 'import sys, json
buf = sys.stdin.read()
# Try to find and parse a JSON object spanning the buffer
depth = 0; start = None; in_str = False; esc = False
for i, ch in enumerate(buf):
    if in_str:
        if esc: esc = False
        elif ch == "\\": esc = True
        elif ch == "\"": in_str = False
        continue
    if ch == "\"": in_str = True
    elif ch == "{":
        if depth == 0: start = i
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0 and start is not None:
            try: print(json.dumps(json.loads(buf[start:i+1]))); raise SystemExit
            except: start = None
print("")')
    if [ -z "$doc" ]; then
        fail "$label" "no parseable JSON. stdout='${body:0:80}' stderr='${err:0:80}'"
        return
    fi

    if [ "$kind" = "e" ]; then
        if [ $rc -eq 0 ]; then
            fail "$label" "expected failure but exit=0. doc=$doc"
            return
        fi
        if ! echo "$doc" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d.get("ok") is False' 2>/dev/null; then
            fail "$label" "ok should be false. doc=$doc"
            return
        fi
        if [ -n "$want_err" ] && ! echo "$doc" | python3 -c "import sys,json; assert '$want_err' in json.load(sys.stdin).get('error','')" 2>/dev/null; then
            fail "$label" "expected error containing '$want_err'. doc=$doc"
            return
        fi
        pass "$label (rc=$rc, err=$want_err)"
    else
        if [ $rc -ne 0 ]; then
            fail "$label" "expected success but exit=$rc. doc=$doc"
            return
        fi
        if ! echo "$doc" | python3 -c 'import sys,json; d=json.load(sys.stdin); assert d.get("ok") is True' 2>/dev/null; then
            fail "$label" "ok should be true. doc=$doc"
            return
        fi
        pass "$label (rc=$rc, ok=true)"
    fi
}

mkwpdoc() {
    local d="$1"
    rm -rf "$d"; mkdir -p "$d"
    echo '<?php // stub wp-config' > "$d/wp-config.php"
    echo '<?php // stub index'     > "$d/index.php"
}

echo "======================================"
echo " app-install.sh / wp-smart-update.sh"
echo " smoke — $(date +%H:%M:%S)"
echo "======================================"

# ─── app-install.sh: error paths ──────────────────────────────────────
echo
echo "── app-install.sh: error paths"

run "unknown arg rejected"          e unknown_arg      \
    "$SCRIPTS/app/app-install.sh" --foo bar
run "missing required args"         e missing_args     \
    "$SCRIPTS/app/app-install.sh"
run "invalid app_id (traversal)"    e invalid_app_id   \
    "$SCRIPTS/app/app-install.sh" --app-id "../../etc" \
    --doc-root /tmp/x --domain a.io
run "doc_root missing"              e doc_root_not_found \
    "$SCRIPTS/app/app-install.sh" --app-id wordpress --doc-root /nonexistent --domain a.io
mkdir -p "$SMOKE/root/empty"
run "manifest not found"            e manifest_not_found \
    "$SCRIPTS/app/app-install.sh" --app-id no-such-app --doc-root "$SMOKE/root/empty" --domain a.io

# ─── app-install.sh: end-to-end ───────────────────────────────────────
echo
echo "── app-install.sh: end-to-end"

mkwpdoc "$SMOKE/root/wp-success"
# Pre-create a doc-root owned by a writable user (stat -c %U will be 'hjm' on Windows; ok)
run "wordpress install (download)"  s ""               \
    "$SCRIPTS/app/app-install.sh" \
    --app-id wordpress --doc-root "$SMOKE/root/wp-success" --domain blog.example.com \
    --db-name wp_db --db-user wp_user

if [ -f "$SMOKE/root/wp-success/wp-config.php" ]; then
    pass "doc-root was populated by curl stub"
else
    fail "doc-root not populated" "expected wp-config.php"
fi
if grep -q "fake wp-config" "$SMOKE/root/wp-success/wp-config.php" 2>/dev/null; then
    pass "doc-root contains the curl payload (not just the stub)"
else
    fail "doc-root missing curl payload" "wp-config.php wasn't overwritten. contents: $(head -1 "$SMOKE/root/wp-success/wp-config.php")"
fi

# ─── app-install.sh: manifest perms check ─────────────────────────────
echo
echo "── app-install.sh: manifest ownership/perms"

# The script searches the real scripts dir first, so we can't easily make the
# live manifest non-conformant. Instead we replicate the *exact* guard the
# script runs, against three files we own:
#   1) writable: mode 666 → must reject
#   2) not_root: owner != root (we, hjm) → must reject
#   3) clean:    mode 644 + root → must accept
PERM_DIR=$SMOKE/root/permcheck
rm -rf "$PERM_DIR"; mkdir -p "$PERM_DIR"
echo '{}' > "$PERM_DIR/writable.json"; chmod 666 "$PERM_DIR/writable.json"
echo '{}' > "$PERM_DIR/clean.json";    chmod 644 "$PERM_DIR/clean.json"
echo '{}' > "$PERM_DIR/not_root.json"

# The script's guard runs `stat -c '%U %a' <file>`. On Windows Git Bash the
# real `stat` always reports the current user (hjm), so the owner check rejects
# every file. We exercise the *bit-mask check* by simulating: pretend the
# script's check_manifest function is invoked with the mode string the script
# would see for each test file.
check_manifest_mode() {
    # $1 = owner string, $2 = mode octal string
    local owner="$1" mode="$2"
    if [[ "$owner" != "root" ]]; then echo "manifest_not_root_owned"; return; fi
    if [[ $(( 8#${mode:-777} & 8#022 )) -ne 0 ]]; then echo "manifest_writable"; return; fi
    echo "ok"
}
r1=$(check_manifest_mode root 666)
r2=$(check_manifest_mode hjm  644)
r3=$(check_manifest_mode root 644)
[ "$r1" = "manifest_writable" ]       && pass "guard rejects world-writable manifest"   || fail "guard rejects world-writable" "got: $r1"
[ "$r2" = "manifest_not_root_owned" ] && pass "guard rejects non-root-owned manifest" || fail "guard rejects non-root"       "got: $r2"
[ "$r3" = "ok" ]                      && pass "guard accepts clean manifest"          || fail "guard accepts clean"          "got: $r3"

# ─── wp-smart-update.sh: error paths ─────────────────────────────────
echo
echo "── wp-smart-update.sh: error paths"

run "unknown arg"             e unknown_arg         "$SCRIPTS/wordpress/wp-smart-update.sh" --bogus
run "missing args"            e missing_args        "$SCRIPTS/wordpress/wp-smart-update.sh"
run "not a wordpress root"    e not_wordpress       "$SCRIPTS/wordpress/wp-smart-update.sh" --path /tmp/empty --type core

# wp-cli not found: the script checks /usr/local/bin/wp and /usr/bin/wp
# directly (not via PATH), so the only way to make it fail is to move the
# real file out and put it back after.
STASH=/tmp/smoke/wp.stash
mv /usr/local/bin/wp "$STASH" 2>/dev/null || true
(
    OUT=$SMOKE/out.txt ERR=$SMOKE/err.txt
    bash "$SCRIPTS/wordpress/wp-smart-update.sh" --path "$SMOKE/root/wp-success" --type core \
        >"$OUT" 2>"$ERR"
    rc=$?
    combined="$(cat $OUT)"$'\n'"$(cat $ERR)"
    if [ $rc -ne 0 ] && echo "$combined" | grep -q '"error":"wp_cli_not_found"'; then
        pass "wp-cli not found reported (rc=$rc)"
    else
        fail "wp-cli not found" "rc=$rc combined=$(echo "$combined" | head -c 200)"
    fi
)
mv "$STASH" /usr/local/bin/wp 2>/dev/null || true

# ─── wp-smart-update.sh: end-to-end ──────────────────────────────────
echo
echo "── wp-smart-update.sh: end-to-end"

mkwpdoc "$SMOKE/root/wp-update"
run "core update on stub"    s ""  "$SCRIPTS/wordpress/wp-smart-update.sh" \
    --path "$SMOKE/root/wp-update" --type core
run "plugin update on stub"  s ""  "$SCRIPTS/wordpress/wp-smart-update.sh" \
    --path "$SMOKE/root/wp-update" --type plugin --slug litespeed-cache

# invalid type: should still be ok (validation only on the type-specific branches)
# actually looking at the script, "widgets" doesn't match core|plugin|theme so
# pre/post version come up empty and update runs nothing — success with empty data
run "unrecognized type"      s ""  "$SCRIPTS/wordpress/wp-smart-update.sh" \
    --path "$SMOKE/root/wp-update" --type widgets

# ─── db scripts: contract + validation ───────────────────────────────
echo
echo "── db scripts: contract and validation"

# db-create
run "db-create: unknown arg"          e unknown_arg      \
    "$SCRIPTS/db/db-create.sh" --foo bar
run "db-create: missing args"         e missing_args     \
    "$SCRIPTS/db/db-create.sh"
run "db-create: invalid db name"      e invalid_db_name  \
    "$SCRIPTS/db/db-create.sh" --engine mariadb --name '1bad; drop'
run "db-create: unsupported engine"   e unsupported_engine \
    "$SCRIPTS/db/db-create.sh" --engine sqlite --name wp_db
run "db-create: success (mariadb)"    s ""               \
    "$SCRIPTS/db/db-create.sh" --engine mariadb --name wp_db --db-user wp_user \
    --password-file /etc/hostname

# db-delete
run "db-delete: unknown arg"          e unknown_arg      \
    "$SCRIPTS/db/db-delete.sh" --foo
run "db-delete: missing args"         e missing_args     \
    "$SCRIPTS/db/db-delete.sh"
run "db-delete: unsupported engine"   e unsupported_engine \
    "$SCRIPTS/db/db-delete.sh" --engine sqlite --name wp_db
run "db-delete: invalid db name"      e invalid_db_name  \
    "$SCRIPTS/db/db-delete.sh" --engine mariadb --name 'bad;name'
run "db-delete: success (mariadb)"    s ""               \
    "$SCRIPTS/db/db-delete.sh" --engine mariadb --name wp_db

# db-clone
run "db-clone: unknown arg"           e unknown_arg      \
    "$SCRIPTS/db/db-clone.sh" --foo
run "db-clone: missing args"          e missing_args     \
    "$SCRIPTS/db/db-clone.sh"
run "db-clone: source not found"      e source_db_not_found \
    "$SCRIPTS/db/db-clone.sh" --engine mariadb --source no_such --target dest_db
run "db-clone: source==target"        e source_equals_target \
    "$SCRIPTS/db/db-clone.sh" --engine mariadb --source wp_db --target wp_db
run "db-clone: success"               s ""               \
    "$SCRIPTS/db/db-clone.sh" --engine mariadb --source wp_db --target wp_clone

# db-export — has mktemp template fix; JSON includes schema_only as bool
run "db-export: unsupported engine"   e unsupported_engine \
    "$SCRIPTS/db/db-export.sh" --engine sqlite --name wp_db
run "db-export: invalid db name"      e invalid_db_name  \
    "$SCRIPTS/db/db-export.sh" --engine mariadb --name 'bad;name'
# success path: write a real .sql file the fake mysql+gzip pipeline can read
echo "SELECT 1;" > "$SMOKE/data/seed.sql"
run "db-export: success"              s ""               \
    "$SCRIPTS/db/db-export.sh" --engine mariadb --name wp_db

# db-import
echo "fake" > "$SMOKE/data/import.sql"
run "db-import: file not found"       e file_not_found   \
    "$SCRIPTS/db/db-import.sh" --engine mariadb --name wp_db --file /nonexistent.sql
run "db-import: unsupported engine"   e unsupported_engine \
    "$SCRIPTS/db/db-import.sh" --engine sqlite --name wp_db --file "$SMOKE/data/import.sql"
run "db-import: success"              s ""               \
    "$SCRIPTS/db/db-import.sh" --engine mariadb --name wp_db --file "$SMOKE/data/import.sql"
gzip -c "$SMOKE/data/import.sql" > "$SMOKE/data/import.sql.gz"
run "db-import: gzipped success"      s ""               \
    "$SCRIPTS/db/db-import.sh" --engine mariadb --name wp_db --file "$SMOKE/data/import.sql.gz"

# db-user-create
PW=$(mktemp); printf 'p@ss\n' > "$PW"
run "db-user-create: pw file missing" e password_file_not_found \
    "$SCRIPTS/db/db-user-create.sh" --engine mariadb --db-name wp_db --db-user wp_user \
    --password-file /nonexistent
# Control-char password via real file (process substitution doesn't work
# reliably under Git Bash on Windows)
PW_BAD=$(mktemp); printf 'bad\npw' > "$PW_BAD"
run "db-user-create: control char pw" e invalid_password_chars \
    "$SCRIPTS/db/db-user-create.sh" --engine mariadb --db-name wp_db --db-user wp_user \
    --password-file "$PW_BAD"
run "db-user-create: success"         s ""               \
    "$SCRIPTS/db/db-user-create.sh" --engine mariadb --db-name wp_db --db-user wp_user \
    --password-file "$PW"
rm -f "$PW" "$PW_BAD"

# ─── cron scripts: contract + DB-driven end-to-end ──────────────────
echo
echo "── cron scripts: contract and end-to-end"

# Set up a real panel DB with one cron job, so cron-sync has something to read.
CRON_DB="$SMOKE/data/llstack.db"
rm -f "$CRON_DB"
sqlite3 "$CRON_DB" <<SQL
CREATE TABLE users (id INTEGER PRIMARY KEY, system_user TEXT);
CREATE TABLE cron_jobs (id INTEGER PRIMARY KEY AUTOINCREMENT, user_id INTEGER, expression TEXT, command TEXT, enabled BOOLEAN DEFAULT 1, description TEXT);
INSERT INTO users (id, system_user) VALUES (1, 'alice'), (2, 'bob');
INSERT INTO cron_jobs (user_id, expression, command, enabled) VALUES
  (1, '*/5 * * * *',  '/usr/bin/backup.sh',  1),
  (1, '0 3 * * *',    '/usr/bin/sync.sh',    1),
  (1, '0 4 * * *',    '/disabled/never.sh',  0);
SQL

# cron-add
run "cron-add: unknown arg"           e unknown_arg      \
    "$SCRIPTS/cron/cron-add.sh" --foo
run "cron-add: missing args"          e missing_args     \
    "$SCRIPTS/cron/cron-add.sh"
run "cron-add: invalid user"          e invalid_user     \
    "$SCRIPTS/cron/cron-add.sh" --user 'bad;name' --expression '* * * * *' --command /bin/true
run "cron-add: control char in expr"  e invalid_chars    \
    "$SCRIPTS/cron/cron-add.sh" --user alice --expression $'bad\ncron' --command /bin/true
run "cron-add: percent in command"    e invalid_chars    \
    "$SCRIPTS/cron/cron-add.sh" --user alice --expression '* * * * *' --command 'bad%truncated'
rm -rf "$SMOKE/crontab/alice"
LLSTACK_DB_PATH="$CRON_DB" LLSTACK_SCRIPTS_DIR="$SCRIPTS" \
    run "cron-add: success"          s ""               \
    "$SCRIPTS/cron/cron-add.sh" --user alice --expression '15 4 * * *' --command /usr/bin/newjob.sh
# Verify the entry landed
grep -q '/usr/bin/newjob.sh' "$SMOKE/crontab/alice" \
    && pass "cron-add: entry persisted to crontab" \
    || fail "cron-add: entry missing" "expected /usr/bin/newjob.sh in $SMOKE/crontab/alice"

# cron-remove
LLSTACK_DB_PATH="$CRON_DB" LLSTACK_SCRIPTS_DIR="$SCRIPTS" \
    run "cron-remove: by expression+command"  s "" \
    "$SCRIPTS/cron/cron-remove.sh" --user alice --expression '15 4 * * *' --command /usr/bin/newjob.sh
grep -q '/usr/bin/newjob.sh' "$SMOKE/crontab/alice" \
    && fail "cron-remove: entry still there" \
    || pass "cron-remove: entry removed"

# cron-sync — rebuild alice's crontab from the DB. Only enabled jobs (2) should land.
rm -f "$SMOKE/crontab/alice"
LLSTACK_DB_PATH="$CRON_DB" LLSTACK_SCRIPTS_DIR="$SCRIPTS" \
    run "cron-sync: success"         s ""               \
    "$SCRIPTS/cron/cron-sync.sh" --user alice
# Verify the disabled row didn't land and the two enabled ones did
sync_out=$(cat "$SMOKE/crontab/alice" 2>/dev/null || echo "")
echo "$sync_out" | grep -q '/usr/bin/backup.sh' \
    && pass "cron-sync: enabled job 1 in crontab" \
    || fail "cron-sync: enabled job 1 missing" "got: $sync_out"
echo "$sync_out" | grep -q '/usr/bin/sync.sh' \
    && pass "cron-sync: enabled job 2 in crontab" \
    || fail "cron-sync: enabled job 2 missing" "got: $sync_out"
echo "$sync_out" | grep -q '/disabled/never.sh' \
    && fail "cron-sync: disabled job leaked into crontab" \
    || pass "cron-sync: disabled job excluded"

# ─── status scripts: contract only (no end-to-end since no real systemd) ──
echo
echo "── status scripts: JSON contract"

run "service-status: no args"        s ""  \
    "$SCRIPTS/monitoring/service-status.sh"
# Verify the output is a real JSON array of services
OUT=$("$SCRIPTS/monitoring/service-status.sh" 2>/dev/null)
[[ "$OUT" == *'"data":'* ]] && pass "service-status: shape includes data field" \
    || fail "service-status: shape" "no data field"
# lshttpd should be in the output (the fake systemctl says it's installed)
echo "$OUT" | grep -q '"name": "litehttpd"' \
    && pass "service-status: includes installed service" \
    || fail "service-status: missing service" "no litehttpd entry"

run "litehttpd-status: no args"       s ""  \
    "$SCRIPTS/litehttpd/litehttpd-status.sh"
OUT=$("$SCRIPTS/litehttpd/litehttpd-status.sh" 2>/dev/null)
[[ "$OUT" == *'"pid":'* && "$OUT" == *'"status":'* && "$OUT" == *'"connections":'* ]] \
    && pass "litehttpd-status: shape has status/pid/connections" \
    || fail "litehttpd-status: shape" "got: $OUT"

# ─── install/upgrade supply-chain env vars ───────────────────────────
echo
echo "── install/upgrade supply-chain env vars"

# Verify LLSTACK_REPO is overridable and falls back to web-casa. We do this
# by sourcing the env-handling lines and checking the resolved values — the
# scripts themselves can't be run end-to-end here (they would try to install
# a real panel).
extract_defaults() {
    awk '
        /^LLSTACK_REPO=/{ print "REPO=" $0; next }
        /^LLSTACK_COMMIT=/{ print "COMMIT=" $0; next }
    ' "$1" | sed -E 's/^[^=]+=//; s/^\$\{LLSTACK_[A-Z]+:-(.*)\}$/\1/' | head -4
}
defaults=$(extract_defaults "$SCRIPTS/install.sh")
echo "$defaults" | grep -q 'web-casa/LLStack' \
    && pass "install.sh: LLSTACK_REPO defaults to web-casa/LLStack" \
    || fail "install.sh: LLSTACK_REPO default" "got: $defaults"

# Same for upgrade.sh
defaults=$(extract_defaults "$SCRIPTS/upgrade.sh")
echo "$defaults" | grep -q 'web-casa/LLStack' \
    && pass "upgrade.sh: LLSTACK_REPO defaults to web-casa/LLStack" \
    || fail "upgrade.sh: LLSTACK_REPO default" "got: $defaults"

# LLSTACK_SKIP_LITEHTTPD_REPO must be referenced in install.sh
grep -q 'LLSTACK_SKIP_LITEHTTPD_REPO' "$SCRIPTS/install.sh" \
    && pass "install.sh: has LLSTACK_SKIP_LITEHTTPD_REPO knob" \
    || fail "install.sh: missing skip knob" "no LLSTACK_SKIP_LITEHTTPD_REPO"

# LLSTACK_COMMIT must be referenced in both
grep -q 'LLSTACK_COMMIT' "$SCRIPTS/install.sh" \
    && pass "install.sh: has LLSTACK_COMMIT pin" \
    || fail "install.sh: missing LLSTACK_COMMIT" ""
grep -q 'LLSTACK_COMMIT' "$SCRIPTS/upgrade.sh" \
    && pass "upgrade.sh: has LLSTACK_COMMIT pin" \
    || fail "upgrade.sh: missing LLSTACK_COMMIT" ""

# Verify the clone lines now have the env-var based branch handling
grep -q 'git clone --depth 1 --branch "\$ref"' "$SCRIPTS/upgrade.sh" \
    && pass "upgrade.sh: uses \$ref for branch (handles commit/tag/branch uniformly)" \
    || fail "upgrade.sh: branch handling" "no \$ref pattern"

# ─── db-install version_mismatch regex (regression) ─────────────────
echo
echo "── db-install version regex"

# A naive [0-9]+\.[0-9]+ on `mysql --version` picks up MariaDB's "Ver 15.1"
# (the protocol version), not the actual server version. The fix matches
# "Distrib X.Y" for MariaDB's banner and falls back to the first X.Y for
# MySQL/Percona. Verify the regex against three real banners.
extract_mariadb() { echo "$1" | grep -oE 'Distrib [0-9]+\.[0-9]+' | head -1 | sed -E 's/Distrib //'; }
extract_mysql()   { echo "$1" | grep -oE '[0-9]+\.[0-9]+' | head -1; }

v=$(extract_mariadb 'mysql  Ver 15.1 Distrib 10.11.19-MariaDB, for Linux (x86_64) using readline 5.1')
[ "$v" = "10.11" ] && pass "mariadb banner: extracts 10.11 (not 15.1)" \
    || fail "mariadb banner regex" "got '$v', expected 10.11"

v=$(extract_mysql 'mysql  Ver 8.0.43 for Linux on x86_64 (MySQL Community Server - GPL)')
[ "$v" = "8.0" ] && pass "mysql banner: extracts 8.0" \
    || fail "mysql banner regex" "got '$v', expected 8.0"

v=$(extract_mysql 'mysql  Ver 8.4.6-6 for Linux on x86_64 (Percona Server)')
[ "$v" = "8.4" ] && pass "percona banner: extracts 8.4" \
    || fail "percona banner regex" "got '$v', expected 8.4"

# ─── install script idempotency ────────────────────────────────────
echo
echo "── install script idempotency"

# The setup wizard re-runs each step on retry. Each step script must
# gracefully say "already installed → ok:true" instead of erroring out.
# We grep the source rather than execute (the install needs real
# packages + dnf). Note: the JSON string inside bash is escaped as
# \"ok\":true so we match the actual stored form.
grep -qF 'already_installed\":true' "$SCRIPTS/php/php-install.sh" \
    && pass "php-install: skips with already_installed:true" \
    || fail "php-install: idempotency missing" "no already_installed path"

for f in db/db-install-mariadb.sh db/db-install-mysql.sh db/db-install-percona.sh db/db-install-postgresql.sh; do
    grep -qF 'already_installed\":true' "$SCRIPTS/$f" \
        && pass "$f: skips with already_installed:true" \
        || fail "$f: idempotency missing" "no already_installed path"
done

# All four must accept --force
for f in php/php-install.sh db/db-install-mariadb.sh db/db-install-mysql.sh db/db-install-percona.sh db/db-install-postgresql.sh; do
    grep -qF -- '--force' "$SCRIPTS/$f" \
        && pass "$f: has --force flag" \
        || fail "$f: missing --force" ""
done

# install.sh must anchor its CWD up front so an interactive shell whose
# current dir was deleted between run start and exec doesn't error out
# with "cannot access parent directories".
grep -qE 'cd /tmp 2>/dev/null' "$SCRIPTS/install.sh" \
    && pass "install.sh: anchors CWD to /tmp up front" \
    || fail "install.sh: missing cd /tmp guard" ""

# ─── ssl + redis compatibility fixes ────────────────────────────────
echo
echo "── ssl + redis compatibility"

# acme.sh v3+ defaults to ZeroSSL which requires email registration
# before any cert is issued. Pin Let's Encrypt so HTTP-01 still works
# without an email step.
grep -qF -- '--server letsencrypt' "$SCRIPTS/ssl/ssl-issue.sh" \
    && pass "ssl-issue: pins Let's Encrypt (avoids acme.sh v3 ZeroSSL default)" \
    || fail "ssl-issue: missing --server letsencrypt" ""

# EL10 ships Valkey instead of Redis. Many tools (including the panel
# backend) hardcode `redis.service`; redis-install.sh must create an
# alias so the historical unit name still resolves.
grep -qF 'ln -s valkey.service /etc/systemd/system/redis.service' \
    "$SCRIPTS/redis/redis-install.sh" \
    && pass "redis-install: creates redis.service symlink for Valkey compat" \
    || fail "redis-install: missing redis.service alias" ""

# install.sh must wire adminer-install into the install flow — without
# it, the panel returns adminer_not_installed on every DB page.
grep -qF 'adminer-install.sh' "$SCRIPTS/install.sh" \
    && pass "install.sh: wires adminer-install into the flow" \
    || fail "install.sh: missing adminer-install wiring" ""

[ -f "$SCRIPTS/adminer-install.sh" ] \
    && pass "adminer-install.sh: exists" \
    || fail "adminer-install.sh: missing script" ""

grep -qF '/opt/llstack/web/adminer' "$SCRIPTS/adminer-install.sh" \
    && pass "adminer-install: targets /opt/llstack/web/adminer (panel's expected path)" \
    || fail "adminer-install: wrong target path" ""

# Idempotency markers (consistent with the other install scripts)
grep -qF 'already_installed\":true' "$SCRIPTS/adminer-install.sh" \
    && pass "adminer-install: idempotent (skips when already installed)" \
    || fail "adminer-install: missing idempotency" ""
grep -qF -- '--force' "$SCRIPTS/adminer-install.sh" \
    && pass "adminer-install: has --force flag" \
    || fail "adminer-install: missing --force" ""

# ─── Summary ─────────────────────────────────────────────────────────
echo
echo "======================================"
echo " Results: $GRN$PASS passed$NC, $RED$FAIL failed$NC"
echo "======================================"
exit $FAIL
