#!/usr/bin/env bash

set -Eeuo pipefail

#############################################
#
# WireGuard Easy Installer
#
# Ubuntu 24.04
#
#############################################

VERSION="1.0"

WG_DIR="/opt/wg-easy"
WG_PORT="51820"
WEB_PORT="51821"       # используется только без HTTPS
DNS="1.1.1.1"
CREDENTIALS_FILE="${WG_DIR}/.admin_credentials"

# Переменные для HTTPS
USE_HTTPS=false
DOMAIN=""
EMAIL=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#############################################

log()   { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }
die()   { error "$1"; exit 1; }

#############################################

banner(){
    clear
    cat <<EOF

==============================================

        WireGuard Easy Installer

              Version ${VERSION}

==============================================

EOF
}

#############################################

check_root(){ [[ $EUID -eq 0 ]] || die "Run installer as root."; }

check_os(){
    source /etc/os-release
    [[ "$ID" == "ubuntu" ]] || die "Ubuntu required."
    [[ "$VERSION_ID" == "24.04" ]] || die "Ubuntu 24.04 required."
}

check_network(){
    ping -c1 1.1.1.1 >/dev/null || die "Internet connection unavailable."
}

update_system(){
    log "Updating packages..."
    apt update
    DEBIAN_FRONTEND=noninteractive apt upgrade -y
}

install_packages(){
    log "Installing packages..."
    apt install -y \
        curl git jq ufw openssl ca-certificates gnupg lsb-release
}

public_ip(){
    for s in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
        IP=$(curl -4 -fs "$s" 2>/dev/null || true)
        if [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
            echo "$IP"
            return
        fi
    done
    die "Cannot determine public IP."
}

random_password(){
    openssl rand -base64 48 | tr -dc 'A-Za-z0-9' | head -c 24
}

# Запрос пароля администратора
ask_password(){
    local pass1 pass2
    log "Set admin password (or leave empty to generate random)"
    while true; do
        read -sp "Enter password: " pass1
        echo
        if [[ -z "$pass1" ]]; then
            ADMIN_PASS=$(random_password)
            log "Generated random password."
            break
        fi
        read -sp "Confirm password: " pass2
        echo
        if [[ "$pass1" == "$pass2" ]]; then
            ADMIN_PASS="$pass1"
            break
        else
            warn "Passwords do not match. Try again."
        fi
    done
}

# Запрос настройки HTTPS
ask_https_config(){
    local answer
    read -p "Do you want to enable HTTPS using Let's Encrypt? (y/N) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        log "HTTPS not enabled. Using HTTP (INSECURE=true)."
        USE_HTTPS=false
        return
    fi

    while true; do
        read -p "Enter your domain (e.g., vpn.example.com): " DOMAIN
        if [[ -z "$DOMAIN" ]]; then
            warn "Domain cannot be empty."
            continue
        fi
        read -p "Enter your email address for Let's Encrypt: " EMAIL
        if [[ -z "$EMAIL" ]]; then
            warn "Email cannot be empty."
            continue
        fi
        break
    done
    USE_HTTPS=true
    log "HTTPS will be enabled for domain $DOMAIN with email $EMAIL"
}

#############################################
# Install Docker
#############################################

install_docker() {
    if command -v docker >/dev/null 2>&1; then
        log "Docker already installed."
        return
    fi
    log "Installing Docker..."
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
    rm -f /tmp/get-docker.sh
    systemctl enable docker
    systemctl start docker
    docker version >/dev/null
}

#############################################
# Check ports availability
#############################################

check_ports(){
    if ss -lun | grep -qE ":${WG_PORT}\b"; then
        die "Port ${WG_PORT}/udp is already in use."
    fi
    if [[ "$USE_HTTPS" == "true" ]]; then
        # Для HTTPS нужны порты 80 и 443
        if ss -ltn | grep -qE ":80\b"; then
            die "Port 80/tcp is already in use (required for Let's Encrypt)."
        fi
        if ss -ltn | grep -qE ":443\b"; then
            die "Port 443/tcp is already in use (required for HTTPS)."
        fi
        log "Ports 80 and 443 are free."
    else
        if ss -ltn | grep -qE ":${WEB_PORT}\b"; then
            die "Port ${WEB_PORT}/tcp is already in use."
        fi
        log "Port ${WEB_PORT}/tcp is free."
    fi
    log "Port ${WG_PORT}/udp is free."
}

#############################################
# Configure Kernel
#############################################

configure_kernel(){
    log "Enable IP Forwarding..."
    cat >/etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.src_valid_mark=1
EOF
    sysctl --system || warn "sysctl warning (ignored)"
}

#############################################
# Configure Firewall
#############################################

configure_firewall(){
    log "Configure UFW..."
    ufw allow OpenSSH || true
    ufw allow ${WG_PORT}/udp
    if [[ "$USE_HTTPS" == "true" ]]; then
        ufw allow 80/tcp
        ufw allow 443/tcp
    else
        ufw allow ${WEB_PORT}/tcp
    fi
    ufw --force enable
}

#############################################
# Create folders
#############################################

create_dirs(){
    mkdir -p "${WG_DIR}"
    mkdir -p "${WG_DIR}/data"
}

#############################################
# Generate credentials (only after password is set)
#############################################

SERVER_IP=$(public_ip)
ADMIN_USER="admin"
ADMIN_PASS=""  # будет установлен позже

save_credentials(){
    if [[ "$USE_HTTPS" == "true" ]]; then
        local url="https://${DOMAIN}"
    else
        local url="http://${SERVER_IP}:${WEB_PORT}"
    fi
    cat > "${CREDENTIALS_FILE}" <<EOF
Admin credentials for WireGuard Easy
URL: ${url}
Username: ${ADMIN_USER}
Password: ${ADMIN_PASS}
EOF
    chmod 600 "${CREDENTIALS_FILE}"
    log "Credentials saved to ${CREDENTIALS_FILE}"
}

#############################################
# Create compose
#############################################

create_compose(){
    if [[ -f "${WG_DIR}/docker-compose.yml" ]]; then
        warn "Existing installation found in ${WG_DIR}."
        read -p "Do you want to overwrite? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            die "Installation aborted by user."
        fi
        cp "${WG_DIR}/docker-compose.yml" "${WG_DIR}/docker-compose.yml.bak.$(date +%s)"
        log "Backup created."
    fi

    log "Creating docker-compose.yml..."
    # Строим блок environment и ports в зависимости от USE_HTTPS
    local env_vars
    local ports_conf

    if [[ "$USE_HTTPS" == "true" ]]; then
        env_vars=$(cat <<-EOM
      - INIT_ENABLED=true
      - INIT_USERNAME=${ADMIN_USER}
      - INIT_PASSWORD=${ADMIN_PASS}
      - INIT_HOST=${DOMAIN}
      - INIT_PORT=${WG_PORT}
      - INIT_DNS=${DNS}
      - LETSENCRYPT_DOMAIN=${DOMAIN}
      - LETSENCRYPT_EMAIL=${EMAIL}
EOM
        )
        ports_conf=$(cat <<-EOM
      - "${WG_PORT}:${WG_PORT}/udp"
      - "80:80"
      - "443:443"
EOM
        )
    else
        env_vars=$(cat <<-EOM
      - INIT_ENABLED=true
      - INIT_USERNAME=${ADMIN_USER}
      - INIT_PASSWORD=${ADMIN_PASS}
      - INIT_HOST=${SERVER_IP}
      - INIT_PORT=${WG_PORT}
      - INIT_DNS=${DNS}
      - INSECURE=true
EOM
        )
        ports_conf=$(cat <<-EOM
      - "${WG_PORT}:${WG_PORT}/udp"
      - "${WEB_PORT}:51821/tcp"
EOM
        )
    fi

    cat > "${WG_DIR}/docker-compose.yml" <<EOF
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15.3.0
    container_name: wg-easy
    restart: unless-stopped
    environment:
${env_vars}
    volumes:
      - ./data:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
${ports_conf}
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
      - NET_RAW
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
EOF
}

#############################################
# Start wg-easy
#############################################

start_wireguard() {
    log "Starting wg-easy..."
    cd "${WG_DIR}"
    docker compose pull
    docker compose up -d
}

#############################################
# Wait Web UI
#############################################

wait_web(){
    if [[ "$USE_HTTPS" == "true" ]]; then
        # Ждём HTTPS (порт 443)
        local check_port=443
        local proto="https"
    else
        local check_port=${WEB_PORT}
        local proto="http"
    fi
    log "Waiting for Web UI to become available (up to ~120s)..."
    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if curl -fs -k "${proto}://127.0.0.1:${check_port}" >/dev/null 2>&1; then
            log "Web UI available."
            return 0
        fi
        sleep 2
        ((attempt++))
    done

    warn "Web UI still not reachable after timeout."
    docker logs --tail 100 wg-easy
    die "Web UI unavailable. Check port, firewall, and container logs."
}

#############################################
# Cleanup compose
#############################################

cleanup_compose(){
    log "Removing INIT_* variables and restarting container with new config..."
    cp "${WG_DIR}/docker-compose.yml" "${WG_DIR}/docker-compose.yml.bak.cleanup"
    sed -i '/INIT_/d' "${WG_DIR}/docker-compose.yml"
    # Если после удаления INIT_* секция environment стала пустой, преобразуем её в {}
    sed -i 's/^\([[:space:]]*\)environment:[[:space:]]*$/\1environment: {}/' "${WG_DIR}/docker-compose.yml"
    cd "${WG_DIR}"
    docker compose up -d --force-recreate
    log "Container recreated without INIT_* variables."
}

#############################################
# Finish
#############################################

finish(){
    if [[ "$USE_HTTPS" == "true" ]]; then
        local url="https://${DOMAIN}"
    else
        local url="http://${SERVER_IP}:${WEB_PORT}"
    fi

    cat <<EOF

==============================================

Installation completed successfully

WireGuard Server
Host: ${SERVER_IP}

Web UI
${url}

Username: ${ADMIN_USER}
Password: ${ADMIN_PASS}

The password has also been saved to:
${CREDENTIALS_FILE}

WireGuard Port: ${WG_PORT}/udp

==============================================

EOF
}

#############################################
# Main
#############################################

main(){
    banner
    check_root
    check_os
    check_network
    update_system
    install_packages
    install_docker
    configure_kernel
    ask_https_config          # Спрашиваем про HTTPS
    check_ports               # Проверяем порты с учётом выбора HTTPS
    configure_firewall
    create_dirs
    ask_password              # Запрашиваем пароль
    save_credentials
    create_compose
    start_wireguard
    wait_web
    cleanup_compose
    finish
}

main "$@"
