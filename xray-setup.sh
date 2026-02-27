#!/bin/sh
# ============================================================
#  Xray VLESS + REALITY + XTLS-Vision — Automated Setup Script
#
#  Supported distros:
#    • Debian / Ubuntu       (systemd, apt)
#    • Alpine Linux          (OpenRC, apk)
#
#  Run as root on a fresh VPS:
#    chmod +x xray-setup.sh && sh xray-setup.sh
#
#  License: MIT
# ============================================================

# ── Bootstrap: ensure bash is available, then re-exec ──
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        echo "[*] bash not found — installing..."
        if command -v apk >/dev/null 2>&1; then
            apk add --no-cache bash
        elif command -v apt >/dev/null 2>&1; then
            apt update -y && apt install -y bash
        else
            echo "[ERROR] Cannot install bash. Install it manually and re-run."
            exit 1
        fi
    fi
    exec bash "$0" "$@"
fi

# ── From here on, we are running in bash ──

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

XRAY_CONFIG="/usr/local/etc/xray/config.json"
XRAY_LOG_DIR="/var/log/xray"

# Populated by detect_environment()
DISTRO=""        # debian | alpine
INIT_SYSTEM=""   # systemd | openrc
PKG_MANAGER=""   # apt | apk
SECURE_ENV=""    # y | n — controls sensitive output visibility
ENABLE_LOGS=""   # y | n — controls Xray access/error logging
BLOCK_TORRENTS="" # y | n — controls BitTorrent protocol blocking
SSH_DAEMON=""    # openssh | dropbear — detected automatically

# ────────────────────────────────────────────────────────────
#  Helper functions
# ────────────────────────────────────────────────────────────
print_header() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}Xray VLESS + Reality + XTLS-Vision Setup${NC}                ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  DPI-resistant proxy server installer                    ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
}

log_info()    { echo -e "${GREEN}[INFO]${NC}    $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC}    $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC}   $1"; }
log_step()    { echo -e "\n${BOLD}${CYAN}▶ Step $1: $2${NC}"; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "This script must be run as root. Use: su -c 'sh $0' or doas sh $0"
        exit 1
    fi
}

check_secure_environment() {
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║${NC}  ${BOLD}🔒 Security Check${NC}                                       ${YELLOW}║${NC}"
    echo -e "${YELLOW}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${YELLOW}║${NC}                                                          ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  This script generates sensitive cryptographic keys.     ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}  Before proceeding, make sure:                           ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}                                                          ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}    • You are ${BOLD}not${NC} in a public place                       ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}    • No cameras can see your screen                      ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}    • No one is standing behind you                       ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}    • You are ${BOLD}not${NC} sharing your screen                     ${YELLOW}║${NC}"
    echo -e "${YELLOW}║${NC}                                                          ${YELLOW}║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "  Are you in a secure environment? [y/N]: " SEC_INPUT

    if [[ "${SEC_INPUT,,}" == "y" || "${SEC_INPUT,,}" == "yes" ]]; then
        SECURE_ENV="y"
        log_info "Secure mode: credentials will be shown during setup."
    else
        SECURE_ENV="n"
        log_info "Safe mode: sensitive data will be hidden. Save to file at the end to retrieve later."
    fi
}

confirm_proceed() {
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║${NC}  ${BOLD}⚠  Overwrite Warning${NC}                                    ${RED}║${NC}"
    echo -e "${RED}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${RED}║${NC}                                                          ${RED}║${NC}"
    echo -e "${RED}║${NC}  This script will overwrite the following if they        ${RED}║${NC}"
    echo -e "${RED}║${NC}  already exist:                                          ${RED}║${NC}"
    echo -e "${RED}║${NC}                                                          ${RED}║${NC}"
    echo -e "${RED}║${NC}    • Xray server configuration and keys                  ${RED}║${NC}"
    echo -e "${RED}║${NC}    • Firewall (iptables) rules                           ${RED}║${NC}"
    echo -e "${RED}║${NC}    • Sysctl network optimizations                        ${RED}║${NC}"
    echo -e "${RED}║${NC}                                                          ${RED}║${NC}"
    echo -e "${RED}║${NC}  Existing firewall rules will be backed up first.        ${RED}║${NC}"
    echo -e "${RED}║${NC}                                                          ${RED}║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "  Continue with installation? [y/N]: " CONFIRM

    if [[ "${CONFIRM,,}" != "y" && "${CONFIRM,,}" != "yes" ]]; then
        log_info "Installation cancelled."
        exit 0
    fi
}

# ────────────────────────────────────────────────────────────
#  Environment detection & service abstraction
# ────────────────────────────────────────────────────────────
detect_environment() {
    # Detect distro
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        case "${ID,,}" in
            alpine)               DISTRO="alpine" ;;
            debian|ubuntu|linuxmint|pop|kali|raspbian)
                                  DISTRO="debian" ;;
            *)
                log_error "Unsupported distro: ${ID}. Supported: Debian/Ubuntu, Alpine."
                exit 1
                ;;
        esac
    elif [[ -f /etc/alpine-release ]]; then
        DISTRO="alpine"
    else
        log_error "Cannot detect distribution. /etc/os-release not found."
        exit 1
    fi

    # Detect init system
    if command -v systemctl &>/dev/null && systemctl --version &>/dev/null 2>&1; then
        INIT_SYSTEM="systemd"
    elif command -v rc-service &>/dev/null; then
        INIT_SYSTEM="openrc"
    else
        log_error "Cannot detect init system. Supported: systemd, OpenRC."
        exit 1
    fi

    # Detect package manager
    if command -v apk &>/dev/null; then
        PKG_MANAGER="apk"
    elif command -v apt &>/dev/null; then
        PKG_MANAGER="apt"
    else
        log_error "No supported package manager found. Need apt or apk."
        exit 1
    fi

    log_info "Detected: ${BOLD}${DISTRO}${NC} / ${BOLD}${INIT_SYSTEM}${NC} / ${BOLD}${PKG_MANAGER}${NC}"
}

# ── Service management abstraction ──
svc_enable() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl enable "$name" 2>/dev/null ;;
        openrc)   rc-update add "$name" default 2>/dev/null ;;
    esac
}

svc_restart() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl daemon-reload; systemctl restart "$name" ;;
        openrc)   rc-service "$name" restart ;;
    esac
}

svc_reload() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl reload "$name" 2>/dev/null || systemctl restart "$name" ;;
        openrc)   rc-service "$name" reload 2>/dev/null || rc-service "$name" restart ;;
    esac
}

svc_is_active() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl is-active --quiet "$name" ;;
        openrc)   rc-service "$name" status 2>/dev/null | grep -qi "started" ;;
    esac
}

svc_disable() {
    local name="$1"
    case "$INIT_SYSTEM" in
        systemd)  systemctl disable "$name" 2>/dev/null; systemctl stop "$name" 2>/dev/null ;;
        openrc)   rc-update del "$name" default 2>/dev/null; rc-service "$name" stop 2>/dev/null ;;
    esac
}

svc_log_hint() {
    if [[ "$ENABLE_LOGS" != "y" && "$INIT_SYSTEM" != "systemd" ]]; then
        echo "xray run -c $XRAY_CONFIG (logging is disabled)"
    else
        case "$INIT_SYSTEM" in
            systemd)  echo "journalctl -u xray -f" ;;
            *)        echo "tail -f /var/log/xray/error.log" ;;
        esac
    fi
}

# ────────────────────────────────────────────────────────────
#  Step 1: System preparation
# ────────────────────────────────────────────────────────────
prepare_system() {
    log_step "1" "Updating system and installing dependencies"

    case "$PKG_MANAGER" in
        apt)
            apt update -y && apt upgrade -y
            # Pre-seed iptables-persistent to avoid interactive prompts
            echo iptables-persistent iptables-persistent/autosave_v4 boolean true | debconf-set-selections
            echo iptables-persistent iptables-persistent/autosave_v6 boolean true | debconf-set-selections
            apt install -y curl wget unzip openssl iptables iptables-persistent qrencode logrotate
            ;;
        apk)
            # Enable community repo (needed for libqrencode-tools)
            if ! grep -q '^\s*[^#].*community' /etc/apk/repositories 2>/dev/null; then
                ALPINE_VER=$(cat /etc/alpine-release 2>/dev/null | cut -d. -f1,2)
                echo "https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VER}/community" >> /etc/apk/repositories
                log_info "Enabled Alpine community repository."
            fi
            apk update && apk upgrade
            apk add curl wget unzip openssl iptables ip6tables libqrencode-tools logrotate bash
            ;;
    esac

    # Disable UFW if present to avoid conflicts with iptables
    if command -v ufw &>/dev/null; then
        svc_disable ufw || true
        log_info "UFW disabled to avoid conflicts with iptables."
    fi

    # Create log directory if logging is enabled
    if [[ "$ENABLE_LOGS" == "y" ]]; then
        mkdir -p "$XRAY_LOG_DIR"
        chmod 755 "$XRAY_LOG_DIR"
    fi
    log_info "System updated and dependencies installed."
}

# ────────────────────────────────────────────────────────────
#  Step 2: Install Xray-core
# ────────────────────────────────────────────────────────────
install_xray() {
    log_step "2" "Installing Xray-core (latest release)"

    # The official install script tries to start xray after installation.
    # Create a minimal placeholder config so it doesn't fail on systemd.
    mkdir -p "$(dirname "$XRAY_CONFIG")"
    if [[ ! -f "$XRAY_CONFIG" ]]; then
        cat > "$XRAY_CONFIG" <<'PLACEHOLDER'
{"inbounds":[],"outbounds":[{"protocol":"freedom"}]}
PLACEHOLDER
        log_info "Created placeholder config (will be replaced in Step 8)."
    fi

    if [[ "$INIT_SYSTEM" == "systemd" ]]; then
        # Official install script works on systemd
        bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install || true
    else
        # Official script refuses non-systemd — install manually
        install_xray_manual
    fi

    # Verify installation
    if command -v xray &>/dev/null; then
        XRAY_VERSION=$(xray version | head -1)
        log_info "Installed: $XRAY_VERSION"
    else
        log_error "Xray installation failed!"
        exit 1
    fi
}

install_xray_manual() {
    log_info "Non-systemd detected — installing Xray manually."

    # Detect architecture
    local ARCH
    case "$(uname -m)" in
        x86_64)          ARCH="64" ;;
        aarch64|arm64)   ARCH="arm64-v8a" ;;
        armv7l|armv7)    ARCH="arm32-v7a" ;;
        i686|i386)       ARCH="32" ;;
        *)               log_error "Unsupported architecture: $(uname -m)"; exit 1 ;;
    esac

    # Get latest release tag from GitHub API
    local LATEST_TAG
    LATEST_TAG=$(curl -s "https://api.github.com/repos/XTLS/Xray-core/releases/latest" \
        | grep '"tag_name"' | head -1 | cut -d'"' -f4)

    if [[ -z "$LATEST_TAG" ]]; then
        log_error "Could not determine latest Xray version from GitHub API."
        exit 1
    fi
    log_info "Latest version: $LATEST_TAG"

    # Download and extract
    local TMPDIR
    TMPDIR=$(mktemp -d)
    local ZIP_URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_TAG}/Xray-linux-${ARCH}.zip"

    log_info "Downloading Xray-linux-${ARCH}.zip..."
    if ! curl -L -o "${TMPDIR}/xray.zip" "$ZIP_URL"; then
        log_error "Download failed: $ZIP_URL"
        rm -rf "$TMPDIR"
        exit 1
    fi

    unzip -o "${TMPDIR}/xray.zip" -d "${TMPDIR}/xray"

    # Install binary
    install -m 755 "${TMPDIR}/xray/xray" /usr/local/bin/xray
    log_info "Binary installed: /usr/local/bin/xray"

    # Install geodata
    mkdir -p /usr/local/share/xray
    if [[ -f "${TMPDIR}/xray/geoip.dat" ]]; then
        install -m 644 "${TMPDIR}/xray/geoip.dat"  /usr/local/share/xray/
        install -m 644 "${TMPDIR}/xray/geosite.dat" /usr/local/share/xray/
    else
        log_info "Downloading geodata files..."
        curl -L -o /usr/local/share/xray/geoip.dat \
            "https://github.com/v2fly/geoip/releases/latest/download/geoip.dat"
        curl -L -o /usr/local/share/xray/geosite.dat \
            "https://github.com/v2fly/domain-list-community/releases/latest/download/dlc.dat"
    fi
    log_info "Geodata installed: /usr/local/share/xray/"

    # Ensure config & log directories exist
    mkdir -p /usr/local/etc/xray
    if [[ "$ENABLE_LOGS" == "y" ]]; then
        mkdir -p "$XRAY_LOG_DIR"
        chmod 755 "$XRAY_LOG_DIR"
    fi

    # Cleanup
    rm -rf "$TMPDIR"

    # Create OpenRC init script
    create_init_script
}

create_init_script() {
    # Detect openrc-run path (moved from /sbin to /usr/sbin in newer Alpine)
    local OPENRC_RUN
    if [[ -x /sbin/openrc-run ]]; then
        OPENRC_RUN="/sbin/openrc-run"
    elif [[ -x /usr/sbin/openrc-run ]]; then
        OPENRC_RUN="/usr/sbin/openrc-run"
    else
        OPENRC_RUN="/sbin/openrc-run"  # fallback
    fi

    local LOG_OUTPUT LOG_ERROR LOG_CHECK
    if [[ "$ENABLE_LOGS" == "y" ]]; then
        LOG_OUTPUT="/var/log/xray/access.log"
        LOG_ERROR="/var/log/xray/error.log"
        LOG_CHECK='checkpath -d -m 0755 -o nobody:nogroup /var/log/xray'
    else
        LOG_OUTPUT="/dev/null"
        LOG_ERROR="/dev/null"
        LOG_CHECK='true'
    fi

    cat > /etc/init.d/xray <<INITEOF
#!${OPENRC_RUN}
# OpenRC init script for Xray

name="xray"
description="Xray proxy service"
command="/usr/local/bin/xray"
command_args="run -c /usr/local/etc/xray/config.json"
command_background=true
pidfile="/run/xray.pid"
output_log="${LOG_OUTPUT}"
error_log="${LOG_ERROR}"

depend() {
    need net
    after firewall
}

start_pre() {
    ${LOG_CHECK}
    /usr/local/bin/xray run -test -c /usr/local/etc/xray/config.json > /dev/null 2>&1
}
INITEOF
    chmod +x /etc/init.d/xray
    log_info "Created /etc/init.d/xray init script (${OPENRC_RUN})."
}

# ────────────────────────────────────────────────────────────
#  Step 3: Choose custom SSH port
# ────────────────────────────────────────────────────────────

# Detect which SSH daemon is running
detect_ssh_daemon() {
    if rc-service dropbear status &>/dev/null 2>&1 || [[ -f /etc/init.d/dropbear ]]; then
        SSH_DAEMON="dropbear"
    elif rc-service sshd status &>/dev/null 2>&1 || [[ -f /etc/init.d/sshd ]] \
         || systemctl is-active --quiet sshd 2>/dev/null || systemctl is-active --quiet ssh 2>/dev/null \
         || [[ -f /etc/ssh/sshd_config ]]; then
        SSH_DAEMON="openssh"
    elif command -v dropbear &>/dev/null; then
        SSH_DAEMON="dropbear"
    elif command -v sshd &>/dev/null; then
        SSH_DAEMON="openssh"
    else
        log_warn "No SSH daemon detected. Assuming OpenSSH."
        SSH_DAEMON="openssh"
    fi
    log_info "SSH daemon: ${BOLD}${SSH_DAEMON}${NC}"
}

# Get current SSH port for dropbear
# Parses DROPBEAR_OPTS in /etc/conf.d/dropbear for -p flag
get_dropbear_port() {
    local CONF="/etc/conf.d/dropbear"
    if [[ -f "$CONF" ]]; then
        # Extract DROPBEAR_OPTS value, then find -p argument
        local OPTS
        OPTS=$(grep -E '^DROPBEAR_OPTS=' "$CONF" 2>/dev/null | sed 's/^DROPBEAR_OPTS=//' | tr -d '"' | tr -d "'") || true
        if [[ -n "$OPTS" ]]; then
            # Parse -p value: could be "-p 2222" or "-p2222" or "-p [addr:]port"
            local PORT
            PORT=$(echo "$OPTS" | grep -oE '\-p\s*[0-9]+' | grep -oE '[0-9]+' | tail -1) || true
            if [[ -n "$PORT" ]]; then
                echo "$PORT"
                return
            fi
        fi
    fi
    echo ""
}

# Get current SSH port for openssh
get_openssh_port() {
    local PORT=""

    # Method 1: Parse sshd_config
    if [[ -f /etc/ssh/sshd_config ]]; then
        PORT=$(grep -E "^Port " /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -1) || true
    fi

    # Method 2: Check sshd_config.d drop-ins
    if [[ -z "$PORT" && -d /etc/ssh/sshd_config.d ]]; then
        PORT=$(grep -rE "^Port " /etc/ssh/sshd_config.d/ 2>/dev/null | awk '{print $2}' | head -1) || true
    fi

    echo "$PORT"
}

# Apply new port for dropbear
apply_dropbear_port() {
    local NEW_PORT="$1"
    local CONF="/etc/conf.d/dropbear"

    # Ensure config file exists
    if [[ ! -f "$CONF" ]]; then
        mkdir -p /etc/conf.d
        echo 'DROPBEAR_OPTS=""' > "$CONF"
    fi

    # Read current DROPBEAR_OPTS
    local OPTS
    OPTS=$(grep -E '^DROPBEAR_OPTS=' "$CONF" | sed 's/^DROPBEAR_OPTS=//' | tr -d '"' | tr -d "'") || true

    # Remove any existing -p flags
    OPTS=$(echo "$OPTS" | sed 's/-p\s*[0-9]*//g; s/  */ /g; s/^ //; s/ $//')

    # Add new port
    if [[ -n "$OPTS" ]]; then
        OPTS="${OPTS} -p ${NEW_PORT}"
    else
        OPTS="-p ${NEW_PORT}"
    fi

    # Write back
    if grep -qE '^DROPBEAR_OPTS=' "$CONF"; then
        sed -i "s|^DROPBEAR_OPTS=.*|DROPBEAR_OPTS=\"${OPTS}\"|" "$CONF"
    else
        echo "DROPBEAR_OPTS=\"${OPTS}\"" >> "$CONF"
    fi

    svc_restart dropbear 2>/dev/null || true
}

# Apply new port for openssh
apply_openssh_port() {
    local NEW_PORT="$1"
    local SSHD_CONFIG="/etc/ssh/sshd_config"

    if grep -qE "^#?Port " "$SSHD_CONFIG"; then
        sed -i "s/^#*Port .*/Port ${NEW_PORT}/" "$SSHD_CONFIG"
    else
        echo "Port ${NEW_PORT}" >> "$SSHD_CONFIG"
    fi

    # Handle sshd_config.d drop-in overrides (Debian/Ubuntu)
    if [[ -d /etc/ssh/sshd_config.d ]]; then
        for f in /etc/ssh/sshd_config.d/*.conf; do
            [[ -f "$f" ]] && sed -i "s/^Port .*/Port ${NEW_PORT}/" "$f" 2>/dev/null || true
        done
    fi

    svc_restart sshd 2>/dev/null || svc_restart ssh 2>/dev/null || true
}

choose_ssh_port() {
    log_step "3" "Configuring SSH port"

    # Detect SSH daemon
    detect_ssh_daemon

    # Detect current SSH port
    CURRENT_SSH_PORT=""
    case "$SSH_DAEMON" in
        dropbear) CURRENT_SSH_PORT=$(get_dropbear_port) ;;
        openssh)  CURRENT_SSH_PORT=$(get_openssh_port) ;;
    esac

    # Fallback: check active session
    if [[ -z "$CURRENT_SSH_PORT" && -n "${SSH_CONNECTION:-}" ]]; then
        CURRENT_SSH_PORT=$(echo "$SSH_CONNECTION" | awk '{print $4}') || true
    fi

    # Final fallback
    CURRENT_SSH_PORT="${CURRENT_SSH_PORT:-22}"

    echo ""
    echo -e "  SSH daemon:       ${BOLD}${SSH_DAEMON}${NC}"
    echo -e "  Current SSH port: ${BOLD}${CURRENT_SSH_PORT}${NC}"
    echo -e "  Using a non-standard port reduces brute-force noise."
    echo -e "  ${YELLOW}⚠ Make sure you can reconnect on the new port before closing this session!${NC}"
    echo ""
    read -rp "  Enter SSH port [default=${CURRENT_SSH_PORT}]: " INPUT_SSH_PORT

    SSH_PORT="${INPUT_SSH_PORT:-$CURRENT_SSH_PORT}"

    # Validate port number
    if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
        log_warn "Invalid port. Falling back to ${CURRENT_SSH_PORT}."
        SSH_PORT="$CURRENT_SSH_PORT"
    fi

    # Apply new SSH port if changed
    if [[ "$SSH_PORT" != "$CURRENT_SSH_PORT" ]]; then
        case "$SSH_DAEMON" in
            dropbear) apply_dropbear_port "$SSH_PORT" ;;
            openssh)  apply_openssh_port "$SSH_PORT" ;;
        esac
        log_info "SSH port changed to ${SSH_PORT}. Update your SSH client!"
    else
        log_info "SSH port kept at ${SSH_PORT}."
    fi
}

# ────────────────────────────────────────────────────────────
#  Step 4: Choose custom Xray inbound port
# ────────────────────────────────────────────────────────────
choose_xray_port() {
    log_step "4" "Configuring Xray inbound port"

    echo ""
    echo -e "  Port ${BOLD}443${NC} is the standard HTTPS port (best for blending in)."
    echo -e "  You can use a different port if 443 is occupied or blocked."
    echo ""
    read -rp "  Enter Xray inbound port [default=443]: " INPUT_XRAY_PORT

    XRAY_PORT="${INPUT_XRAY_PORT:-443}"

    # Validate port number
    if ! [[ "$XRAY_PORT" =~ ^[0-9]+$ ]] || (( XRAY_PORT < 1 || XRAY_PORT > 65535 )); then
        log_warn "Invalid port. Falling back to 443."
        XRAY_PORT="443"
    fi

    # Warn if same as SSH
    if [[ "$XRAY_PORT" == "$SSH_PORT" ]]; then
        log_error "Xray port cannot be the same as SSH port (${SSH_PORT})!"
        read -rp "  Enter a different Xray port: " XRAY_PORT
    fi

    log_info "Xray will listen on port ${XRAY_PORT}."
}

# ────────────────────────────────────────────────────────────
#  Step 5: Choose DNS providers
# ────────────────────────────────────────────────────────────

DNS_NAMES=(
    "DNS.SB"
    "Mullvad DNS"
    "Quad9"
    "Quad9 Unfiltered"
    "Cloudflare"
    "AdGuard DNS"
)
DNS_URLS=(
    "doh.dns.sb/dns-query"
    "dns.mullvad.net/dns-query"
    "dns.quad9.net/dns-query"
    "dns11.quad9.net/dns-query"
    "1.1.1.1/dns-query"
    "dns.adguard-dns.com/dns-query"
)
DNS_INFO=(
    "Germany   | No logging"
    "Sweden    | Zero logs, audited"
    "Switzerland| No IP logging, threat blocking"
    "Switzerland| No IP logging, no filtering"
    "USA       | Logs purged 24h, KPMG-audited"
    "Cyprus    | Aggregated anon stats, ad blocking"
)

choose_dns() {
    log_step "5" "Choosing DNS providers (DoH)"

    echo ""
    echo -e "  All queries from Xray will use encrypted DNS-over-HTTPS."
    echo -e "  Choose a ${BOLD}primary${NC} and ${BOLD}secondary${NC} provider from the list below."
    echo ""
    echo -e "  ${BOLD}#   Provider            Jurisdiction     Logging${NC}"
    echo -e "  ─────────────────────────────────────────────────────────────"
    for i in "${!DNS_NAMES[@]}"; do
        printf "    %d)  %-20s %s\n" $((i+1)) "${DNS_NAMES[$i]}" "${DNS_INFO[$i]}"
    done
    echo ""

    # Primary DNS
    read -rp "  Primary DNS [1-${#DNS_NAMES[@]}, default=1 (DNS.SB)]: " INPUT_DNS1
    DNS1_IDX=$(( ${INPUT_DNS1:-1} - 1 ))
    if (( DNS1_IDX < 0 || DNS1_IDX >= ${#DNS_NAMES[@]} )); then
        log_warn "Invalid choice. Falling back to DNS.SB."
        DNS1_IDX=0
    fi

    # Secondary DNS
    read -rp "  Secondary DNS [1-${#DNS_NAMES[@]}, default=2 (Mullvad DNS)]: " INPUT_DNS2
    DNS2_IDX=$(( ${INPUT_DNS2:-2} - 1 ))
    if (( DNS2_IDX < 0 || DNS2_IDX >= ${#DNS_NAMES[@]} )); then
        log_warn "Invalid choice. Falling back to Mullvad DNS."
        DNS2_IDX=1
    fi

    if [[ "$DNS1_IDX" == "$DNS2_IDX" ]]; then
        log_warn "Primary and secondary are the same. Consider picking different providers for redundancy."
    fi

    DNS1_NAME="${DNS_NAMES[$DNS1_IDX]}"
    DNS1_URL="${DNS_URLS[$DNS1_IDX]}"
    DNS2_NAME="${DNS_NAMES[$DNS2_IDX]}"
    DNS2_URL="${DNS_URLS[$DNS2_IDX]}"

    echo ""
    log_info "Primary DNS:   ${DNS1_NAME} (${DNS1_URL})"
    log_info "Secondary DNS: ${DNS2_NAME} (${DNS2_URL})"
}

# ────────────────────────────────────────────────────────────
#  Logging preference
# ────────────────────────────────────────────────────────────
choose_logging() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}📋 Logging Preference${NC}                                   ${CYAN}║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  Logs help with debugging but also record connection     ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  metadata (timestamps, IPs, traffic volume).             ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  For maximum privacy, disable logging entirely.          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  You can re-enable it later in the Xray config.          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "  Enable logging? [y/N]: " LOG_INPUT

    if [[ "${LOG_INPUT,,}" == "y" || "${LOG_INPUT,,}" == "yes" ]]; then
        ENABLE_LOGS="y"
        mkdir -p "$XRAY_LOG_DIR"
        chmod 755 "$XRAY_LOG_DIR"
        log_info "Logging enabled: access + error logs in /var/log/xray/"
    else
        ENABLE_LOGS="n"
        log_info "Logging disabled: no connection data will be stored."
    fi
}

# ────────────────────────────────────────────────────────────
#  BitTorrent blocking preference
# ────────────────────────────────────────────────────────────
choose_torrent_blocking() {
    echo ""
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║${NC}  ${BOLD}🚫 BitTorrent Blocking${NC}                                  ${CYAN}║${NC}"
    echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
    echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  Torrents through a proxy can get your VPS IP flagged    ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  or banned by the hosting provider. They also generate   ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  high-volume traffic patterns that are easy to detect.   ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  If you only use this proxy for web browsing, blocking   ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}  BitTorrent is recommended.                              ${CYAN}║${NC}"
    echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
    echo ""
    read -rp "  Block BitTorrent traffic? [y/N]: " BT_INPUT

    if [[ "${BT_INPUT,,}" == "y" || "${BT_INPUT,,}" == "yes" ]]; then
        BLOCK_TORRENTS="y"
        log_info "BitTorrent blocking enabled."
    else
        BLOCK_TORRENTS="n"
        log_info "BitTorrent traffic allowed through proxy."
    fi
}

# ────────────────────────────────────────────────────────────
#  Step 6: Generate credentials
# ────────────────────────────────────────────────────────────
generate_credentials() {
    log_step "6" "Generating cryptographic credentials"

    UUID=$(xray uuid)

    # Output format varies by Xray version:
    #   Old: "Private key: xxx" / "Public key: xxx"
    #   New: "PrivateKey: xxx"  / "Password: xxx"  / "Hash32: xxx"
    KEY_OUTPUT=$(xray x25519 2>&1) || true
    PRIVATE_KEY=$(echo "$KEY_OUTPUT" | awk '/rivate/{print $NF}')
    PUBLIC_KEY=$(echo "$KEY_OUTPUT" | awk '/ublic|assword/{print $NF; exit}')

    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        log_error "Failed to generate x25519 key pair."
        log_error "xray x25519 output was:"
        echo "$KEY_OUTPUT"
        exit 1
    fi

    SHORT_ID_1=$(openssl rand -hex 3)
    SHORT_ID_2=$(openssl rand -hex 6)

    if [[ "$SECURE_ENV" == "y" ]]; then
        log_info "UUID:        $UUID"
        log_info "Private Key: $PRIVATE_KEY"
        log_info "Public Key:  $PUBLIC_KEY"
        log_info "Short IDs:   (empty), $SHORT_ID_1, $SHORT_ID_2"
    else
        log_info "Credentials generated successfully (hidden — safe mode)."
    fi
}

# ────────────────────────────────────────────────────────────
#  Step 7: Choose a camouflage destination site
# ────────────────────────────────────────────────────────────
choose_dest_site() {
    log_step "7" "Choosing camouflage destination (dest) site"

    echo ""
    echo -e "  The ${BOLD}dest${NC} site is what your server pretends to be."
    echo -e "  Requirements: TLS 1.3, HTTP/2, X25519 certificate, NOT behind CDN."
    echo ""
    echo -e "  ${BOLD}Recommended options:${NC}"
    echo "    1) www.microsoft.com         (default, very reliable)"
    echo "    2) www.samsung.com"
    echo "    3) www.mozilla.org"
    echo "    4) www.logitech.com"
    echo "    5) Enter custom domain"
    echo ""
    read -rp "  Choose [1-5, default=1]: " DEST_CHOICE

    case "${DEST_CHOICE:-1}" in
        1) DEST_DOMAIN="www.microsoft.com" ;;
        2) DEST_DOMAIN="www.samsung.com" ;;
        3) DEST_DOMAIN="www.mozilla.org" ;;
        4) DEST_DOMAIN="www.logitech.com" ;;
        5)
            read -rp "  Enter domain (e.g., example.com): " CUSTOM_DOMAIN
            DEST_DOMAIN="${CUSTOM_DOMAIN}"
            ;;
        *) DEST_DOMAIN="www.microsoft.com" ;;
    esac

    log_info "Camouflage dest: $DEST_DOMAIN"

    log_info "Verifying $DEST_DOMAIN supports TLS 1.3 + H2..."
    TLS_OUTPUT=$(xray tls ping "$DEST_DOMAIN" 2>&1) || true
    if echo "$TLS_OUTPUT" | grep -qi "handshake succeeded"; then
        if echo "$TLS_OUTPUT" | grep -qi "TLS 1.3"; then
            log_info "$DEST_DOMAIN — TLS 1.3 verified ✔"
        else
            log_warn "$DEST_DOMAIN — Handshake OK but TLS 1.3 not confirmed."
        fi
    else
        log_warn "Could not fully verify $DEST_DOMAIN. Proceeding anyway."
        log_warn "You can manually check: xray tls ping $DEST_DOMAIN"
    fi
}

# ────────────────────────────────────────────────────────────
#  Step 8: Build and write server config
# ────────────────────────────────────────────────────────────
write_config() {
    log_step "8" "Writing Xray server configuration"

    SERVER_IP=$(curl -4 -s ifconfig.me || curl -4 -s icanhazip.com || echo "<SERVER_IP>")

    # Build optional BitTorrent blocking rule
    local BT_RULE=""
    if [[ "$BLOCK_TORRENTS" == "y" ]]; then
        BT_RULE=',
            {
                "type": "field",
                "protocol": ["bittorrent"],
                "outboundTag": "block"
            }'
    fi

    mkdir -p "$(dirname "$XRAY_CONFIG")"

    cat > "$XRAY_CONFIG" <<XRAY_EOF
{
    "log": {
        "loglevel": "$(if [[ "$ENABLE_LOGS" == "y" ]]; then echo warning; else echo none; fi)",
        "access": "$(if [[ "$ENABLE_LOGS" == "y" ]]; then echo /var/log/xray/access.log; else echo none; fi)",
        "error": "$(if [[ "$ENABLE_LOGS" == "y" ]]; then echo /var/log/xray/error.log; else echo none; fi)"
    },
    "dns": {
        "servers": [
            "https+local://${DNS1_URL}",
            "https+local://${DNS2_URL}",
            "localhost"
        ],
        "queryStrategy": "UseIP"
    },
    "routing": {
        "domainStrategy": "IPIfNonMatch",
        "rules": [
            {
                "type": "field",
                "ip": ["geoip:private"],
                "outboundTag": "block"
            }${BT_RULE},
            {
                "type": "field",
                "domain": ["geosite:category-ads-all"],
                "outboundTag": "block"
            }
        ]
    },
    "inbounds": [
        {
            "listen": "0.0.0.0",
            "port": ${XRAY_PORT},
            "protocol": "vless",
            "tag": "vless-reality-in",
            "settings": {
                "clients": [
                    {
                        "id": "${UUID}",
                        "email": "user1@xray",
                        "flow": "xtls-rprx-vision"
                    }
                ],
                "decryption": "none"
            },
            "streamSettings": {
                "network": "tcp",
                "security": "reality",
                "realitySettings": {
                    "show": false,
                    "dest": "${DEST_DOMAIN}:443",
                    "xver": 0,
                    "serverNames": [
                        "${DEST_DOMAIN}"
                    ],
                    "privateKey": "${PRIVATE_KEY}",
                    "shortIds": [
                        "",
                        "${SHORT_ID_1}",
                        "${SHORT_ID_2}"
                    ]
                }
            },
            "sniffing": {
                "enabled": true,
                "destOverride": ["http", "tls", "quic"],
                "routeOnly": true
            }
        }
    ],
    "outbounds": [
        {
            "tag": "direct",
            "protocol": "freedom"
        },
        {
            "tag": "block",
            "protocol": "blackhole"
        }
    ],
    "policy": {
        "levels": {
            "0": {
                "handshake": 2,
                "connIdle": 120,
                "uplinkOnly": 1,
                "downlinkOnly": 1
            }
        },
        "system": {
            "statsOutboundUplink": false,
            "statsOutboundDownlink": false
        }
    }
}
XRAY_EOF

    chmod 644 "$XRAY_CONFIG"
    log_info "Config written to $XRAY_CONFIG"
}

# ────────────────────────────────────────────────────────────
#  Step 9: Configure firewall
# ────────────────────────────────────────────────────────────
configure_firewall() {
    log_step "9" "Configuring firewall (iptables)"

    RULES_V4="/etc/iptables/rules.v4"
    RULES_V6="/etc/iptables/rules.v6"

    # ── Backup existing rules if present ──
    mkdir -p /etc/iptables
    BACKUP_TS=$(date +%Y%m%d_%H%M%S)

    if [[ -f "$RULES_V4" ]]; then
        cp "$RULES_V4" "${RULES_V4}.bak.${BACKUP_TS}"
        log_info "Backed up ${RULES_V4} → ${RULES_V4}.bak.${BACKUP_TS}"
    fi
    if [[ -f "$RULES_V6" ]]; then
        cp "$RULES_V6" "${RULES_V6}.bak.${BACKUP_TS}"
        log_info "Backed up ${RULES_V6} → ${RULES_V6}.bak.${BACKUP_TS}"
    fi

    # ── Write IPv4 rules ──
    cat > "$RULES_V4" <<RULES4_EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

# Loopback
-A INPUT -i lo -j ACCEPT

# Established & related connections
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Drop invalid packets early
-A INPUT -m conntrack --ctstate INVALID -j DROP

# SSH brute-force protection: max 6 new connections per 60s per IP
-A INPUT -p tcp --dport ${SSH_PORT} -m conntrack --ctstate NEW -m recent --set --name SSH --rsource
-A INPUT -p tcp --dport ${SSH_PORT} -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 6 --name SSH --rsource -j DROP

# Allow SSH
-A INPUT -p tcp --dport ${SSH_PORT} -j ACCEPT

# Allow Xray
-A INPUT -p tcp --dport ${XRAY_PORT} -j ACCEPT

# Allow ICMP ping
-A INPUT -p icmp --icmp-type echo-request -j ACCEPT

COMMIT
RULES4_EOF

    # ── Write IPv6 rules ──
    cat > "$RULES_V6" <<RULES6_EOF
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]

# Loopback
-A INPUT -i lo -j ACCEPT

# Established & related connections
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# Drop invalid packets early
-A INPUT -m conntrack --ctstate INVALID -j DROP

# Allow SSH
-A INPUT -p tcp --dport ${SSH_PORT} -j ACCEPT

# Allow Xray
-A INPUT -p tcp --dport ${XRAY_PORT} -j ACCEPT

# Allow ICMPv6 (required for IPv6 neighbor discovery, etc.)
-A INPUT -p icmpv6 -j ACCEPT

COMMIT
RULES6_EOF

    # ── Load rules atomically ──
    iptables-restore < "$RULES_V4"
    log_info "IPv4 rules loaded: SSH ${SSH_PORT}/tcp, Xray ${XRAY_PORT}/tcp"

    ip6tables-restore < "$RULES_V6" 2>/dev/null || log_warn "IPv6 rules skipped (ip6tables not available)."

    # ── Persist rules across reboots (distro-specific) ──
    case "$INIT_SYSTEM" in
        systemd)
            # netfilter-persistent (installed via iptables-persistent)
            systemctl enable netfilter-persistent 2>/dev/null || true
            ;;
        openrc)
            # Create a simple init script that restores rules on boot
            # Detect openrc-run path (moved from /sbin to /usr/sbin in newer Alpine)
            local OPENRC_RUN
            if [[ -x /sbin/openrc-run ]]; then
                OPENRC_RUN="/sbin/openrc-run"
            elif [[ -x /usr/sbin/openrc-run ]]; then
                OPENRC_RUN="/usr/sbin/openrc-run"
            else
                OPENRC_RUN="/sbin/openrc-run"
            fi

            cat > /etc/init.d/iptables-xray <<FWEOF
#!${OPENRC_RUN}
# Restore iptables rules on boot

name="iptables-xray"
description="Restore iptables rules for Xray"

depend() {
    before xray
    need net
}

start() {
    local PATH="/usr/sbin:/sbin:/usr/bin:/bin:\${PATH}"
    ebegin "Restoring iptables rules"
    if [ -f /etc/iptables/rules.v4 ]; then
        iptables-restore < /etc/iptables/rules.v4
    fi
    if [ -f /etc/iptables/rules.v6 ] && command -v ip6tables-restore >/dev/null 2>&1; then
        ip6tables-restore < /etc/iptables/rules.v6
    fi
    eend \$?
}

stop() {
    local PATH="/usr/sbin:/sbin:/usr/bin:/bin:\${PATH}"
    ebegin "Flushing iptables rules"
    iptables -F
    iptables -P INPUT ACCEPT
    eend \$?
}
FWEOF
            chmod +x /etc/init.d/iptables-xray
            svc_enable iptables-xray
            log_info "Created /etc/init.d/iptables-xray for boot persistence."
            ;;
    esac

    log_info "Firewall configured and will persist across reboots."
}

# ────────────────────────────────────────────────────────────
#  Step 10: Configure log rotation
# ────────────────────────────────────────────────────────────
configure_logrotate() {
    log_step "10" "Configuring log rotation for Xray"

    if [[ "$ENABLE_LOGS" != "y" ]]; then
        log_info "Logging disabled — skipping log rotation setup."
        return 0
    fi

    mkdir -p /etc/logrotate.d

    cat > /etc/logrotate.d/xray <<LOGROTATE_EOF
/var/log/xray/*.log {
    weekly
    rotate 12
    compress
    delaycompress
    missingok
    notifempty
    create 0644 nobody nogroup
    sharedscripts
    postrotate
        $(
            case "$INIT_SYSTEM" in
                systemd)  echo 'systemctl reload xray > /dev/null 2>&1 || true' ;;
                openrc)   echo 'rc-service xray reload > /dev/null 2>&1 || kill -HUP \$(cat /run/xray.pid 2>/dev/null) 2>/dev/null || true' ;;
            esac
        )
    endscript
}
LOGROTATE_EOF

    chmod 644 /etc/logrotate.d/xray

    # Alpine: ensure logrotate cron job exists
    if [[ "$DISTRO" == "alpine" ]]; then
        if [[ ! -f /etc/periodic/daily/logrotate ]]; then
            mkdir -p /etc/periodic/daily
            cat > /etc/periodic/daily/logrotate <<'CRONEOF'
#!/bin/sh
/usr/sbin/logrotate /etc/logrotate.conf
CRONEOF
            chmod +x /etc/periodic/daily/logrotate
        fi
        svc_enable crond 2>/dev/null || true
        svc_restart crond 2>/dev/null || true
    fi

    log_info "Logrotate configured: weekly rotation, 12 weeks retention, compressed."
}

# ────────────────────────────────────────────────────────────
#  Step 11: Apply sysctl optimizations
# ────────────────────────────────────────────────────────────
optimize_sysctl() {
    log_step "11" "Applying network optimizations (BBR + buffers)"

    # Ensure sysctl.d directory exists (Alpine may not have it)
    mkdir -p /etc/sysctl.d

    cat > /etc/sysctl.d/99-xray-optimize.conf <<'SYSCTL_EOF'
# === TCP BBR Congestion Control ===
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# === TCP Buffer Tuning ===
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216

# === Connection Tuning ===
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_mtu_probing = 1
net.ipv4.ip_forward = 1

# === Security ===
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
SYSCTL_EOF

    sysctl --system > /dev/null 2>&1 || sysctl -p /etc/sysctl.d/99-xray-optimize.conf > /dev/null 2>&1
    log_info "BBR congestion control and TCP optimizations applied."
}

# ────────────────────────────────────────────────────────────
#  Step 12: Start Xray service
# ────────────────────────────────────────────────────────────
start_xray() {
    log_step "12" "Starting Xray service"

    # Regenerate init script with final log settings (non-systemd only)
    if [[ "$INIT_SYSTEM" != "systemd" ]]; then
        create_init_script
    fi

    # Test config first
    if xray run -test -c "$XRAY_CONFIG" 2>/dev/null; then
        log_info "Config validation passed."
    else
        log_error "Config validation FAILED. Check $XRAY_CONFIG"
        xray run -test -c "$XRAY_CONFIG"
        exit 1
    fi

    svc_enable xray
    svc_restart xray

    sleep 2
    if svc_is_active xray; then
        log_info "Xray is running successfully!"
    else
        log_error "Xray failed to start. Check: $(svc_log_hint)"
        exit 1
    fi
}

# ────────────────────────────────────────────────────────────
#  Step 13: Print summary & client connection info
# ────────────────────────────────────────────────────────────
print_summary() {
    log_step "13" "Setup complete!"

    VLESS_LINK="vless://${UUID}@${SERVER_IP}:${XRAY_PORT}?type=tcp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=${DEST_DOMAIN}&sid=${SHORT_ID_1}&flow=xtls-rprx-vision#Xray-Reality"

    # Build distro-appropriate management commands
    local SVC_STATUS SVC_RESTART SVC_LOGS FW_RELOAD
    case "$INIT_SYSTEM" in
        systemd)
            SVC_STATUS="systemctl status xray"
            SVC_RESTART="systemctl restart xray"
            SVC_LOGS="journalctl -u xray -f"
            FW_RELOAD="netfilter-persistent reload"
            ;;
        openrc)
            SVC_STATUS="rc-service xray status"
            SVC_RESTART="rc-service xray restart"
            SVC_LOGS="tail -f /var/log/xray/error.log"
            FW_RELOAD="rc-service iptables-xray restart"
            ;;
    esac

    echo ""
    echo -e "${GREEN}  ✔ Xray is running on port ${XRAY_PORT}${NC}"
    echo -e "${GREEN}  ✔ Firewall configured${NC}"
    echo -e "${GREEN}  ✔ BBR congestion control enabled${NC}"
    if [[ "$ENABLE_LOGS" == "y" ]]; then
        echo -e "${GREEN}  ✔ Log rotation configured (12 weeks)${NC}"
    else
        echo -e "${GREEN}  ✔ Logging disabled (no connection data stored)${NC}"
    fi
    if [[ "$BLOCK_TORRENTS" == "y" ]]; then
        echo -e "${GREEN}  ✔ BitTorrent traffic blocked${NC}"
    else
        echo -e "${GREEN}  ✔ BitTorrent traffic allowed${NC}"
    fi
    echo -e "${GREEN}  ✔ Distro: ${DISTRO} / Init: ${INIT_SYSTEM}${NC}"
    echo ""

    if [[ "$SSH_PORT" != "22" ]]; then
        echo -e "  ${RED}${BOLD}⚠ SSH PORT CHANGED to ${SSH_PORT}! (${SSH_DAEMON})${NC}"
        echo -e "  ${RED}  Reconnect with: ssh -p ${SSH_PORT} root@${SERVER_IP}${NC}"
        echo ""
    fi

    # ── Ask: Show credentials? ──
    if [[ "$SECURE_ENV" == "y" ]]; then
        echo -e "  ${BOLD}Display server credentials now?${NC}"
        echo -e "  ${YELLOW}⚠ Contains sensitive data (UUID, keys).${NC}"
        echo ""
        read -rp "  Show credentials? [Y/n]: " SHOW_CREDS
        SHOW_CREDS="${SHOW_CREDS:-y}"
    else
        log_info "Credentials display skipped (safe mode)."
        SHOW_CREDS="n"
    fi

    if [[ "${SHOW_CREDS,,}" == "y" || "${SHOW_CREDS,,}" == "yes" ]]; then
        echo ""
        echo -e "${CYAN}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${CYAN}║${NC}  ${BOLD}SERVER CREDENTIALS${NC}                                      ${CYAN}║${NC}"
        echo -e "${CYAN}╠══════════════════════════════════════════════════════════╣${NC}"
        echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
        echo -e "${CYAN}║${NC}  Server IP:    ${GREEN}${SERVER_IP}${NC}"
        echo -e "${CYAN}║${NC}  Xray Port:    ${GREEN}${XRAY_PORT}${NC}"
        echo -e "${CYAN}║${NC}  SSH Port:     ${GREEN}${SSH_PORT}${NC}"
        echo -e "${CYAN}║${NC}  Protocol:     ${GREEN}VLESS${NC}"
        echo -e "${CYAN}║${NC}  UUID:         ${GREEN}${UUID}${NC}"
        echo -e "${CYAN}║${NC}  Flow:         ${GREEN}xtls-rprx-vision${NC}"
        echo -e "${CYAN}║${NC}  Security:     ${GREEN}Reality${NC}"
        echo -e "${CYAN}║${NC}  SNI:          ${GREEN}${DEST_DOMAIN}${NC}"
        echo -e "${CYAN}║${NC}  Fingerprint:  ${GREEN}chrome${NC}"
        echo -e "${CYAN}║${NC}  Public Key:   ${GREEN}${PUBLIC_KEY}${NC}"
        echo -e "${CYAN}║${NC}  Short ID:     ${GREEN}${SHORT_ID_1}${NC}"
        echo -e "${CYAN}║${NC}  DNS Primary:  ${GREEN}${DNS1_NAME}${NC}"
        echo -e "${CYAN}║${NC}  DNS Secondary:${GREEN}${DNS2_NAME}${NC}"
        echo -e "${CYAN}║${NC}                                                          ${CYAN}║${NC}"
        echo -e "${CYAN}╚══════════════════════════════════════════════════════════╝${NC}"
        echo ""
    else
        log_info "Credentials hidden. You can view them later via the save file or config."
    fi

    # ── Ask: Show VLESS share link? ──
    if [[ "$SECURE_ENV" == "y" ]]; then
        echo -e "  ${BOLD}Display VLESS share link now?${NC}"
        echo -e "  ${YELLOW}⚠ This is a one-line connection string with your full credentials.${NC}"
        echo ""
        read -rp "  Show share link? [Y/n]: " SHOW_LINK
        SHOW_LINK="${SHOW_LINK:-y}"
    else
        log_info "Share link display skipped (safe mode)."
        SHOW_LINK="n"
    fi

    if [[ "${SHOW_LINK,,}" == "y" || "${SHOW_LINK,,}" == "yes" ]]; then
        echo ""
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        echo -e "  ${BOLD}VLESS Share Link (paste into client app):${NC}"
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        echo ""
        echo -e "${GREEN}${VLESS_LINK}${NC}"
        echo ""
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        echo -e "  ${BOLD}Recommended Client Apps:${NC}"
        echo -e "    • Android:  ${GREEN}v2rayNG / NekoBox${NC}"
        echo -e "    • iOS:      ${GREEN}Streisand / V2Box / FoXray${NC}"
        echo -e "    • Windows:  ${GREEN}v2rayN / Hiddify / NekoRay${NC}"
        echo -e "    • macOS:    ${GREEN}V2Box / FoXray / NekoRay${NC}"
        echo -e "    • Linux:    ${GREEN}NekoRay / v2rayA / Hiddify${NC}"
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        echo ""
    else
        log_info "Share link hidden. You can retrieve it later via the save file."
    fi

    # ── Ask: Show QR code? ──
    if [[ "$SECURE_ENV" == "y" ]]; then
        echo -e "  ${BOLD}Display QR code for client import?${NC}"
        echo -e "  ${YELLOW}⚠ The QR code contains the same credentials as the share link.${NC}"
        echo ""
        read -rp "  Show QR code? [Y/n]: " SHOW_QR
        SHOW_QR="${SHOW_QR:-y}"
    else
        log_info "QR code display skipped (safe mode)."
        SHOW_QR="n"
    fi

    if [[ "${SHOW_QR,,}" == "y" || "${SHOW_QR,,}" == "yes" ]]; then
        echo ""
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        echo -e "  ${BOLD}Scan with your client app (v2rayNG, Streisand, etc.):${NC}"
        echo -e "${CYAN}──────────────────────────────────────────────────────────${NC}"
        echo ""
        qrencode -t ANSIUTF8 "${VLESS_LINK}"
        echo ""
    else
        log_info "QR code hidden. You can generate it later with:"
        echo -e "           ${YELLOW}qrencode -t ANSIUTF8 'YOUR_VLESS_LINK'${NC}"
    fi

    # ── Always show: non-sensitive management info ──
    echo -e "  ${BOLD}Client Settings:${NC}"
    echo -e "    Fingerprint  = ${YELLOW}chrome${NC} (or firefox/safari/random)"
    echo -e "    Network      = ${YELLOW}tcp${NC}"
    echo -e "    Security     = ${YELLOW}reality${NC}"
    echo -e "    Flow         = ${YELLOW}xtls-rprx-vision${NC}"
    echo ""
    echo -e "  ${BOLD}Manage Xray:${NC}"
    echo -e "    Status:    ${YELLOW}${SVC_STATUS}${NC}"
    echo -e "    Restart:   ${YELLOW}${SVC_RESTART}${NC}"
    if [[ "$ENABLE_LOGS" == "y" ]]; then
        echo -e "    Logs:      ${YELLOW}${SVC_LOGS}${NC}"
    else
        echo -e "    Logs:      ${YELLOW}disabled (edit loglevel in config to re-enable)${NC}"
    fi
    echo -e "    Config:    ${YELLOW}nano $XRAY_CONFIG${NC}"
    echo -e "    Add user:  ${YELLOW}xray uuid${NC} → add to clients array"
    echo ""
    echo -e "  ${BOLD}Firewall:${NC}"
    echo -e "    View rules:  ${YELLOW}iptables -L -n --line-numbers${NC}"
    echo -e "    Reload:      ${YELLOW}${FW_RELOAD}${NC}"
    echo ""

    # ── Ask: Save credentials to file? ──
    if [[ "$SECURE_ENV" == "y" ]]; then
        echo -e "  ${BOLD}Save credentials to /root/xray-credentials.txt?${NC}"
        echo -e "  This file will contain your private key and share link."
        echo -e "  ${YELLOW}⚠ Convenient but a security risk if the server is compromised.${NC}"
        echo ""
        read -rp "  Save credentials to file? [y/N]: " SAVE_CREDS
    else
        echo ""
        echo -e "  ${BOLD}Save credentials to /root/xray-credentials.txt?${NC}"
        echo -e "  Since you're in safe mode, this is the recommended way to"
        echo -e "  retrieve your credentials later in a secure environment."
        echo ""
        read -rp "  Save credentials to file? [Y/n]: " SAVE_CREDS
        SAVE_CREDS="${SAVE_CREDS:-y}"
    fi

    if [[ "${SAVE_CREDS,,}" == "y" || "${SAVE_CREDS,,}" == "yes" ]]; then
        CREDS_FILE="/root/xray-credentials.txt"
        local CREDS_LOGS
        if [[ "$ENABLE_LOGS" == "y" ]]; then
            CREDS_LOGS="${SVC_LOGS}"
        else
            CREDS_LOGS="disabled"
        fi

        cat > "$CREDS_FILE" <<CREDS_EOF
===== XRAY REALITY SERVER CREDENTIALS =====
Generated: $(date)
Distro:       ${DISTRO} / ${INIT_SYSTEM}
SSH daemon:   ${SSH_DAEMON}
Logging:      $(if [[ "$ENABLE_LOGS" == "y" ]]; then echo "enabled"; else echo "disabled"; fi)
BitTorrent:   $(if [[ "$BLOCK_TORRENTS" == "y" ]]; then echo "blocked"; else echo "allowed"; fi)

Server IP:    ${SERVER_IP}
Xray Port:    ${XRAY_PORT}
SSH Port:     ${SSH_PORT}
Protocol:     VLESS
UUID:         ${UUID}
Flow:         xtls-rprx-vision
Security:     Reality
SNI:          ${DEST_DOMAIN}
Fingerprint:  chrome
Public Key:   ${PUBLIC_KEY}
Private Key:  ${PRIVATE_KEY}
Short IDs:    (empty), ${SHORT_ID_1}, ${SHORT_ID_2}
DNS Primary:  ${DNS1_NAME} (${DNS1_URL})
DNS Secondary: ${DNS2_NAME} (${DNS2_URL})

VLESS Share Link:
${VLESS_LINK}

Config file:  ${XRAY_CONFIG}

Management:
  Status:     ${SVC_STATUS}
  Restart:    ${SVC_RESTART}
  Logs:       ${CREDS_LOGS}
  Firewall:   ${FW_RELOAD}
  SSH:        ssh -p ${SSH_PORT} root@${SERVER_IP}
CREDS_EOF
        chmod 600 "$CREDS_FILE"
        log_info "Credentials saved to ${CREDS_FILE}"
    else
        log_info "Credentials NOT saved to disk. Make sure you have them recorded."
    fi
}

# ────────────────────────────────────────────────────────────
#  Main
# ────────────────────────────────────────────────────────────
main() {
    print_header
    check_root
    check_secure_environment
    confirm_proceed
    detect_environment
    prepare_system
    install_xray
    choose_ssh_port
    choose_xray_port
    choose_dns
    choose_logging
    choose_torrent_blocking
    generate_credentials
    choose_dest_site
    write_config
    configure_firewall
    configure_logrotate
    optimize_sysctl
    start_xray
    print_summary
}

main "$@"
