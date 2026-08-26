#!/bin/bash
set -euo pipefail

# LLStack Panel Installer
# Installs ONLY essential components. PHP/DB/extras are selected in the web wizard.
# Usage: curl -sSL https://install.llstack.com | bash

LLSTACK_DIR="/opt/llstack"
LLSTACK_USER="llstack"
LLSTACK_PORT=30333
# LLSTACK_REPO is the source for the panel's own code. The previous version
# hardcoded the upstream author's repo, which means a fork user testing
# this installer pulled the *author's* tree — including any of their
# unmerged or pushed-but-not-reviewed changes — instead of their own. Now
# overridable via env so a fork can install its own tree, and so a CI /
# reproducible build can pin to a specific tag or commit.
LLSTACK_REPO="${LLSTACK_REPO:-https://github.com/web-casa/LLStack}"
# Optional commit/tag/branch to pin the panel install to. When unset, the
# branch HEAD is used (current default behaviour). Setting this is the
# only way to get a reproducible install — without it, "git clone" pulls
# whatever the repo's HEAD happens to be at install time.
LLSTACK_COMMIT="${LLSTACK_COMMIT:-}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${GREEN}[LLStack]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; }
banner() {
    echo -e "${BLUE}"
    echo "  _     _     ____  _             _    "
    echo " | |   | |   / ___|| |_ __ _  ___| | __"
    echo " | |   | |   \___ \| __/ _\` |/ __| |/ /"
    echo " | |___| |___ ___) | || (_| | (__|   < "
    echo " |_____|_____|____/ \__\__,_|\___|_|\_\\"
    echo -e "${NC}"
    echo " Server Control Panel Installer"
    echo ""
}

# ── Pre-checks ──

check_root() {
    if [[ $EUID -ne 0 ]]; then err "Must be run as root"; exit 1; fi
}

check_os() {
    [[ -f /etc/os-release ]] || { err "Cannot detect OS"; exit 1; }
    . /etc/os-release
    case "$ID" in
        almalinux|rocky|centos|ol|rhel) ;;
        *) err "Unsupported: $ID. Only EL9/EL10."; exit 1 ;;
    esac
    MAJOR_VER="${VERSION_ID%%.*}"
    [[ "$MAJOR_VER" == "9" || "$MAJOR_VER" == "10" ]] || { err "Only EL9/EL10"; exit 1; }
    log "Detected: $NAME $VERSION_ID (EL$MAJOR_VER)"
}

check_resources() {
    local mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo)
    local disk=$(df -BG / | awk 'NR==2{print $4}' | tr -d 'G')
    if [[ $disk -lt 5 ]]; then err "Need ≥5GB disk"; exit 1; fi
    log "Resources: $((mem_kb/1024))MB RAM, ${disk}GB disk"
}

check_existing() {
    if [[ -d "$LLSTACK_DIR" ]]; then
        warn "$LLSTACK_DIR exists. Use upgrade.sh"
        exit 1
    fi
}

# ── Essential installs only ──

install_base() {
    log "Installing base dependencies..."
    /usr/bin/crb enable 2>/dev/null || true
    dnf install -y epel-release 2>&1 | tail -1
    dnf install -y curl wget tar gzip unzip git jq python3.12 python3.12-pip \
        libxcrypt-compat sqlite 2>&1 | tail -1
    # Node.js is NOT needed — frontend is pre-built
}

install_repos() {
    log "Adding REMI repository (for PHP later)..."
    if ! rpm -q remi-release &>/dev/null; then
        dnf install -y "https://rpms.remirepo.net/enterprise/remi-release-${MAJOR_VER}.rpm" 2>&1 | tail -1
    fi
    dnf module reset php -y 2>/dev/null || true
}

install_litehttpd() {
    log "Installing LiteHttpd..."
    # The setup.sh at rpms.litehttpd.com is fetched and piped to bash as
    # root. This is a remote-script-as-RCE pattern: anyone who can serve
    # a response on that domain (DNS hijack, registrar compromise, or
    # the domain's owner themselves) gets arbitrary code execution on
    # every box that runs this installer. There is no signature check
    # and no checksum in the URL. Refusing to make this the only
    # install path makes the operator decide.
    if [[ "${LLSTACK_SKIP_LITEHTTPD_REPO:-}" == "1" ]]; then
        warn "LLSTACK_SKIP_LITEHTTPD_REPO=1 — skipping rpms.litehttpd.com repo setup (you must add the repo manually)"
    else
        warn "About to run: curl -s https://rpms.litehttpd.com/setup.sh | bash"
        warn "This fetches a remote shell script and runs it as root."
        warn "To skip: set LLSTACK_SKIP_LITEHTTPD_REPO=1 (you will need to add the LiteHttpd yum repo manually)."
        curl -s https://rpms.litehttpd.com/setup.sh | bash 2>&1 | tail -1
    fi
    dnf install -y openlitespeed-litehttpd 2>&1 | tail -1
    systemctl enable lshttpd
}

install_acme() {
    log "Installing acme.sh..."
    if [[ ! -d "/root/.acme.sh" ]]; then
        curl -s https://get.acme.sh | sh 2>&1 | tail -1
    fi
}

setup_panel() {
    log "Setting up LLStack panel..."

    if ! id "$LLSTACK_USER" &>/dev/null; then
        useradd -r -s /sbin/nologin -d "$LLSTACK_DIR" "$LLSTACK_USER"
    fi

    mkdir -p "$LLSTACK_DIR"/{data,logs,backups}

    # Copy or clone panel files
    if [[ -e "/opt/llstack-panel" ]]; then
        # Refuse symlinks: a privileged local user can plant a symlink at
        # /opt/llstack-panel pointing at a directory they control, and the
        # subsequent `cp -r` will follow it and run whatever code lives there
        # as root (gunicorn runs as root — see setup_service below).
        if [[ -L "/opt/llstack-panel" ]]; then
            err "/opt/llstack-panel is a symlink; refusing to install (it would let a local user inject code run as root)"
            err "  Replace with a real directory: rm /opt/llstack-panel && mkdir /opt/llstack-panel"
            exit 1
        fi
        if [[ ! -d "/opt/llstack-panel" ]]; then
            err "/opt/llstack-panel exists but is not a directory"
            exit 1
        fi
        cp -r /opt/llstack-panel/backend "$LLSTACK_DIR/"
        cp -r /opt/llstack-panel/web "$LLSTACK_DIR/"
        cp -r /opt/llstack-panel/scripts "$LLSTACK_DIR/"
        cp -r /opt/llstack-panel/config "$LLSTACK_DIR/" 2>/dev/null || true
        cp /opt/llstack-panel/VERSION "$LLSTACK_DIR/VERSION" 2>/dev/null || true
        cp /opt/llstack-panel/versions.json "$LLSTACK_DIR/versions.json" 2>/dev/null || true
        cp -r /opt/llstack-panel/templates "$LLSTACK_DIR/" 2>/dev/null || true
    else
        # mktemp -d, not a fixed /tmp path: a symlink planted at /tmp/llstack-src
        # by a local user is followed by both the clone and the cp below, which
        # copies whatever they put there into $LLSTACK_DIR and runs it as root.
        SRC_DIR=$(mktemp -d /tmp/llstack-src.XXXXXXXXXX)
        chmod 700 "$SRC_DIR"
        if [[ -n "$LLSTACK_COMMIT" ]]; then
            # SHAs off the default branch can't be fetched with --depth 1
            # (the server only ships the tip of the remote's HEAD). A full
            # clone is the only way to ask the server to find an arbitrary
            # commit; the cost is one full checkout of the panel repo, which
            # is small in practice.
            git clone "$LLSTACK_REPO" "$SRC_DIR/repo" >&2
            git -C "$SRC_DIR/repo" checkout "$LLSTACK_COMMIT" >&2
        else
            git clone --depth 1 "$LLSTACK_REPO" "$SRC_DIR/repo" >&2
        fi
        cp -r "$SRC_DIR"/repo/{backend,web,scripts,config,templates} "$LLSTACK_DIR/"
        cp "$SRC_DIR/repo/VERSION" "$LLSTACK_DIR/VERSION" 2>/dev/null || true
        cp "$SRC_DIR/repo/versions.json" "$LLSTACK_DIR/versions.json" 2>/dev/null || true
        rm -rf "$SRC_DIR"
    fi

    # Python
    log "Setting up Python environment..."
    python3.12 -m venv "$LLSTACK_DIR/backend/.venv"
    "$LLSTACK_DIR/backend/.venv/bin/pip" install -q -r "$LLSTACK_DIR/backend/requirements.txt"

    # Frontend — pre-built dist/ is included, no Node.js needed
    if [[ ! -d "$LLSTACK_DIR/web/dist" ]]; then
        err "Pre-built frontend not found at $LLSTACK_DIR/web/dist"
        err "Clone from the release or run 'npm run build' on a dev machine first"
        exit 1
    fi
    log "Frontend pre-built dist/ found ($(ls "$LLSTACK_DIR/web/dist/assets/"*.js 2>/dev/null | wc -l) chunks)"

    # serve_app.py ships in the repo (backend/serve_app.py). Do NOT regenerate it here:
    # a heredoc copy is a second source of truth that silently discards repo-side fixes.
    if [[ ! -f "$LLSTACK_DIR/backend/serve_app.py" ]]; then
        err "backend/serve_app.py missing from the release — cannot start the panel"
        exit 1
    fi

    chmod +x "$LLSTACK_DIR/scripts"/*/*.sh "$LLSTACK_DIR/scripts"/*.sh 2>/dev/null || true

    # Ownership: code (backend/scripts/web/config/templates) stays root-owned so the
    # panel service account cannot rewrite a script that sudoers lets it run as root
    # — that combination is a privilege-escalation path. Only mutable state is owned
    # by the panel user. The service itself runs as root, so it can write everywhere.
    chown -R root:root "$LLSTACK_DIR"
    chmod 755 "$LLSTACK_DIR"
    chown -R "$LLSTACK_USER:$LLSTACK_USER" \
        "$LLSTACK_DIR/data" "$LLSTACK_DIR/logs" "$LLSTACK_DIR/backups"
    chmod 750 "$LLSTACK_DIR/data" "$LLSTACK_DIR/logs" "$LLSTACK_DIR/backups"
}

setup_sudoers() {
    log "Configuring sudoers..."
    # A Cmnd listed as a bare path allows any arguments (sudoers semantics), which is
    # what the management scripts need. Do NOT add `bash <script>` or `env * <script>`
    # forms: specifying args makes sudo require an exact pattern match (breaking real
    # arguments), and an `env *` wildcard spans spaces, allowing
    # `sudo env BASH_ENV=/tmp/x bash <script>` — arbitrary root execution.
    # llstack-ctl invokes scripts directly (shebang), which matches this rule.
    cat > /etc/sudoers.d/llstack << SUDOEOF
$LLSTACK_USER ALL=(root) NOPASSWD: $LLSTACK_DIR/scripts/*/*.sh
SUDOEOF
    chmod 440 /etc/sudoers.d/llstack
    # A single-character typo in a sudoers file disables sudo for the whole
    # system. Validate before leaving it in place; on failure, remove the
    # broken file and abort so the operator can fix it manually rather than
    # being locked out.
    if ! visudo -c -f /etc/sudoers.d/llstack >/dev/null 2>&1; then
        rm -f /etc/sudoers.d/llstack
        err "Generated sudoers file failed validation; removed and aborting"
        err "  (a typo in the file would have locked out all sudo on this host)"
        exit 1
    fi
}

setup_service() {
    log "Creating systemd service..."
    cat > /etc/systemd/system/llstack.service << SVCEOF
[Unit]
Description=LLStack Panel
After=network.target
[Service]
Type=exec
User=root
WorkingDirectory=$LLSTACK_DIR/backend
Environment=LLSTACK_DB_PATH=$LLSTACK_DIR/data/llstack.db
Environment=LLSTACK_SCRIPTS_DIR=$LLSTACK_DIR/scripts
ExecStart=$LLSTACK_DIR/backend/.venv/bin/gunicorn -w 1 --threads 4 -b 127.0.0.1:8001 serve_app:app --timeout 120
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
SVCEOF
    systemctl daemon-reload
    systemctl enable --now llstack
}

setup_litehttpd_proxy() {
    log "Configuring LiteHttpd panel reverse proxy..."
    local VHOST_DIR="/usr/local/lsws/conf/vhosts/llstack-panel"
    mkdir -p "$VHOST_DIR"

    # Self-signed cert
    local CERT_DIR="/usr/local/lsws/conf/ssl/panel"
    mkdir -p "$CERT_DIR"
    openssl req -x509 -newkey rsa:2048 -keyout "$CERT_DIR/privkey.pem" \
        -out "$CERT_DIR/fullchain.pem" -days 365 -nodes \
        -subj "/CN=llstack-panel" 2>/dev/null

    cp "$LLSTACK_DIR/config/panel-vhost.conf" "$VHOST_DIR/vhconf.conf" 2>/dev/null || true
    sed -i "s|/opt/llstack/web/dist|$LLSTACK_DIR/web/dist|g" "$VHOST_DIR/vhconf.conf"

    local CONF="/usr/local/lsws/conf/httpd_config.conf"

    # Change Default listener from 8088 to 80 (LiteHttpd ships with 8088)
    sed -i 's/address.*\*:8088/address                  *:80/' "$CONF"

    if ! grep -q "virtualhost llstack-panel" "$CONF"; then
        cat >> "$CONF" << LEOF

virtualhost llstack-panel {
  vhRoot                  $VHOST_DIR
  configFile              $VHOST_DIR/vhconf.conf
  allowSymbolLink         1
  enableScript            1
}

listener llstack {
  address                 *:$LLSTACK_PORT
  secure                  1
  keyFile                 $CERT_DIR/privkey.pem
  certFile                $CERT_DIR/fullchain.pem
  map                     llstack-panel *
}
LEOF
    fi

    systemctl start lshttpd 2>/dev/null || true
}

setup_selinux() {
    if command -v getenforce &>/dev/null && [[ "$(getenforce)" != "Disabled" ]]; then
        log "Configuring SELinux..."
        bash "$LLSTACK_DIR/scripts/selinux-setup.sh" 2>&1 | grep -E '^\[SELinux\]' || true
    fi
}

setup_ssl_cron() {
    log "Setting up SSL auto-renewal cron..."
    local ssl_cmd="0 3 * * * $LLSTACK_DIR/scripts/ssl/ssl-check-renew.sh >> /var/log/llstack-ssl-renew.log 2>&1"
    local db_cmd="30 2 * * * $LLSTACK_DIR/scripts/backup/backup-panel-db.sh >> /var/log/llstack-panel-backup.log 2>&1"
    local wp_cmd="*/30 * * * * $LLSTACK_DIR/scripts/wordpress/wp-auto-update-check.sh 2>&1"
    local disk_cmd="15 * * * * $LLSTACK_DIR/scripts/system/user-disk-refresh.sh >> /var/log/llstack-disk-refresh.log 2>&1"
    ( (crontab -l 2>/dev/null || true) | grep -v ssl-check-renew | grep -v backup-panel-db | grep -v wp-auto-update-check | grep -v user-disk-refresh || true; echo "$ssl_cmd"; echo "$db_cmd"; echo "$wp_cmd"; echo "$disk_cmd") | crontab -
}

setup_logrotate() {
    log "Setting up log rotation..."
    cp "$LLSTACK_DIR/config/logrotate-llstack" /etc/logrotate.d/llstack 2>/dev/null || true
    chmod 644 /etc/logrotate.d/llstack 2>/dev/null || true
}

setup_firewall() {
    log "Configuring firewall..."
    if command -v firewall-cmd &>/dev/null; then
        # SSH must be added explicitly: a non-default zone, or a minimal EL
        # install, may not have the ssh service in the active zone, and the
        # next --reload would otherwise cut the operator off mid-install.
        firewall-cmd --permanent --add-service=ssh 2>/dev/null || true
        firewall-cmd --permanent --add-port="${LLSTACK_PORT}/tcp" 2>/dev/null || true
        firewall-cmd --permanent --add-service=http --add-service=https 2>/dev/null || true
        firewall-cmd --reload 2>/dev/null || true
    fi
}

get_public_ip() {
    # Try multiple services for reliability
    local ip=""
    ip=$(curl -s --max-time 3 https://api.ipify.org 2>/dev/null) && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return
    ip=$(curl -s --max-time 3 https://ifconfig.me 2>/dev/null) && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return
    ip=$(curl -s --max-time 3 https://icanhazip.com 2>/dev/null | tr -d '[:space:]') && [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && echo "$ip" && return
    # Fallback to local IP
    hostname -I | awk '{print $1}'
}

print_summary() {
    local ip=$(get_public_ip)
    echo ""
    echo -e "${GREEN}============================================${NC}"
    echo -e "${GREEN}  LLStack installed successfully!${NC}"
    echo -e "${GREEN}============================================${NC}"
    echo ""
    echo -e "  Panel:  ${BLUE}https://${ip}:${LLSTACK_PORT}${NC}"
    echo ""
    echo -e "  1. Open the URL above"
    echo -e "  2. Create your admin account"
    echo -e "  3. Choose PHP versions, databases, and extras"
    echo -e "     (installed via the web setup wizard)"
    echo ""
    echo -e "  ${YELLOW}No PHP or databases are installed yet.${NC}"
    echo -e "  ${YELLOW}The setup wizard will guide you through it.${NC}"
    echo ""
}

main() {
    banner
    check_root
    check_os
    check_resources
    check_existing

    install_base
    install_repos
    install_litehttpd
    install_acme
    setup_panel
    setup_sudoers
    setup_service
    setup_litehttpd_proxy
    setup_selinux
    setup_ssl_cron
    setup_firewall
    setup_logrotate
    # Install llstack-ctl CLI
    ln -sf "$LLSTACK_DIR/scripts/llstack-ctl" /usr/local/bin/llstack-ctl
    print_summary
}

main "$@"
