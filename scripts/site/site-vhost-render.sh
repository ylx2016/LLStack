#!/bin/bash
set -euo pipefail

# Render vhost config from template + custom config JSON
# Usage: site-vhost-render.sh --domain <domain> --doc-root <path> --php <version> \
#        [--aliases <a1,a2>] [--custom-json <path>] [--ssl-key <path> --ssl-cert <path>]

DOMAIN="" DOC_ROOT="" PHP_VERSION="php83" ALIASES="" CUSTOM_JSON="" SSL_KEY="" SSL_CERT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --domain)      DOMAIN="$2"; shift 2 ;;
        --doc-root)    DOC_ROOT="$2"; shift 2 ;;
        --php)         PHP_VERSION="$2"; shift 2 ;;
        --aliases)     ALIASES="$2"; shift 2 ;;
        --custom-json) CUSTOM_JSON="$2"; shift 2 ;;
        --ssl-key)     SSL_KEY="$2"; shift 2 ;;
        --ssl-cert)    SSL_CERT="$2"; shift 2 ;;
        *) shift ;;
    esac
done

if [[ -z "$DOMAIN" || -z "$DOC_ROOT" ]]; then
    echo '{"ok":false,"error":"missing_args"}' >&2; exit 1
fi

# Validate domain format
if ! echo "$DOMAIN" | grep -qP '^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$'; then
    echo '{"ok":false,"error":"invalid_domain"}' >&2; exit 1
fi

# Validate doc_root is an absolute path under allowed directories
if [[ ! "$DOC_ROOT" =~ ^/(home|opt|var)/[a-zA-Z0-9._-]+/ ]]; then
    echo '{"ok":false,"error":"invalid_doc_root"}' >&2; exit 1
fi

VHOST_DIR="/usr/local/lsws/conf/vhosts/$DOMAIN"
VHOST_CONF="$VHOST_DIR/vhconf.conf"
TEMPLATE_DIR="${LLSTACK_TEMPLATES_DIR:-/opt/llstack/templates}"
TEMPLATE="$TEMPLATE_DIR/vhost.conf.tpl"
PHP_SHORT="${PHP_VERSION//php/}"

# Fallback to bundled template in repo
if [[ ! -f "$TEMPLATE" ]]; then
    SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
    TEMPLATE="$SCRIPT_DIR/../../templates/vhost.conf.tpl"
fi

if [[ ! -f "$TEMPLATE" ]]; then
    echo '{"ok":false,"error":"template_not_found"}' >&2; exit 1
fi

# Per-domain lock to prevent concurrent config corruption
LOCK_FILE="/var/lock/llstack-vhost-${DOMAIN}.lock"
exec 200>"$LOCK_FILE"
flock -w 5 200 || { echo '{"ok":false,"error":"config_locked"}' >&2; exit 1; }

# Render template using Python (safe for multiline values, no injection risk)
mkdir -p "$VHOST_DIR"

RENDERED=$(python3 - "$TEMPLATE" "$DOMAIN" "$DOC_ROOT" "$PHP_SHORT" "$ALIASES" \
    "$CUSTOM_JSON" "$SSL_KEY" "$SSL_CERT" << 'PYEOF'
import json, os, sys

template_path = sys.argv[1]
domain = sys.argv[2]
doc_root = sys.argv[3]
php_short = sys.argv[4]
aliases = sys.argv[5]
custom_json_path = sys.argv[6]
ssl_key = sys.argv[7]
ssl_cert = sys.argv[8]

# Read template
with open(template_path) as f:
    tpl = f.read()

# Validate aliases (comma-separated list of valid domain names) to prevent
# config injection into vhconf.conf via unsanitized aliases.
import re as _re
_DOMAIN_RE = _re.compile(r'^(?:[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$')
def _valid_domain(d): return bool(_DOMAIN_RE.match(d))

if aliases:
    _parts = [x.strip() for x in aliases.split(',') if x.strip()]
    for _a in _parts:
        if not _valid_domain(_a):
            print(json.dumps({"ok": False, "error": "invalid_alias", "message": "Invalid alias: " + _a}), file=sys.stderr)
            sys.exit(1)
    aliases = ",".join(_parts)

# Build alias config line
alias_conf = f"vhAliases                 {aliases}" if aliases else ""

# Read custom config from JSON
custom = {}
if custom_json_path and os.path.isfile(custom_json_path):
    try:
        with open(custom_json_path) as f:
            custom = json.load(f)
        os.unlink(custom_json_path)
    except Exception:
        pass

# Substitute template variables (safe string replacement, no regex)
replacements = {
    "{{DOC_ROOT}}": doc_root,
    "{{DOMAIN}}": domain,
    "{{PHP_SHORT}}": php_short,
    "{{ALIAS_CONF}}": alias_conf,
    "{{CUSTOM_HEAD}}": custom.get("CUSTOM_HEAD", ""),
    "{{CUSTOM_HANDLER}}": custom.get("CUSTOM_HANDLER", ""),
    "{{CUSTOM_REWRITE}}": custom.get("CUSTOM_REWRITE", ""),
    "{{CUSTOM_PHP}}": custom.get("CUSTOM_PHP", ""),
    "{{CUSTOM_TAIL}}": custom.get("CUSTOM_TAIL", ""),
    "{{CACHE_CONFIG}}": custom.get("CACHE_CONFIG", ""),
}

for placeholder, value in replacements.items():
    # Sanitize: remove null bytes from all values
    value = value.replace("\x00", "")
    tpl = tpl.replace(placeholder, value)

# Append SSL block if certs exist
if ssl_key and ssl_cert and os.path.isfile(ssl_key) and os.path.isfile(ssl_cert):
    tpl += f"""
vhssl  {{
  keyFile                 {ssl_key}
  certFile                {ssl_cert}
  certChain               1
  sslProtocol             24
}}
"""

print(tpl)
PYEOF
)

# Backup current config for rollback
if [[ -f "$VHOST_CONF" ]]; then
    cp "$VHOST_CONF" "${VHOST_CONF}.bak"
fi

# Atomic write: temp file + rename
TMPFILE=$(mktemp "$VHOST_DIR/.vhconf.XXXXXXXXXX.tmp")
printf '%s\n' "$RENDERED" > "$TMPFILE"
chmod 644 "$TMPFILE"
mv "$TMPFILE" "$VHOST_CONF"

# Validate config by restarting (lswsctrl has no configtest)
/usr/local/lsws/bin/lswsctrl restart &>/dev/null || true
sleep 1
if ! pgrep -f "litespeed|lshttpd|openlitespeed" &>/dev/null; then
    if [[ -f "${VHOST_CONF}.bak" ]]; then
        mv "${VHOST_CONF}.bak" "$VHOST_CONF"
        /usr/local/lsws/bin/lswsctrl restart &>/dev/null || true
    fi
    echo '{"ok":false,"error":"config_validation_failed","message":"Config validation failed, changes reverted"}' >&2
    exit 1
fi

rm -f "${VHOST_CONF}.bak"
/usr/local/lsws/bin/lswsctrl reload &>/dev/null || true

echo '{"ok":true}'
