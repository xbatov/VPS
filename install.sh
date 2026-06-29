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

WEB_PORT="51821"

DNS="1.1.1.1"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

#############################################

log(){
    echo -e "${GREEN}[INFO]${NC} $1"
}

warn(){
    echo -e "${YELLOW}[WARN]${NC} $1"
}

error(){
    echo -e "${RED}[ERROR]${NC} $1"
}

die(){
    error "$1"
    exit 1
}

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

check_root(){
    [[ $EUID -eq 0 ]] || die "Run installer as root."
}

#############################################

check_os(){
    source /etc/os-release
    [[ "$ID" == "ubuntu" ]] || die "Ubuntu required."
    [[ "$VERSION_ID" == "24.04" ]] || die "Ubuntu 24.04 required."
}

#############################################

check_network(){
    ping -c1 1.1.1.1 >/dev/null \
        || die "Internet connection unavailable."
}

#############################################

update_system(){
    log "Updating packages..."
    apt update
    DEBIAN_FRONTEND=noninteractive apt upgrade -y
}

#############################################

install_packages(){
    log "Installing packages..."
    apt install -y \
        curl \
        git \
        jq \
        ufw \
        openssl \
        ca-certificates \
        gnupg \
        lsb-release
}

#############################################

public_ip(){
    for s in \
        https://api.ipify.org \
        https://ifconfig.me/ip \
        https://ipv4.icanhazip.com
    do
        IP=$(curl -4 -fs "$s" 2>/dev/null || true)
        if [[ "$IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
        then
            echo "$IP"
            return
        fi
    done
    die "Cannot determine public IP."
}

#############################################

random_password(){
    openssl rand -base64 48 \
        | tr -dc 'A-Za-z0-9' \
        | head -c 24
}

#############################################
# Install Docker
#############################################

install_docker() {
    if command -v docker >/dev/null 2>&1
    then
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
    if ss -ltn | grep -qE ":${WEB_PORT}\b"; then
        die "Port ${WEB_PORT}/tcp is already in use."
    fi
    log "Ports ${WG_PORT}/udp and ${WEB_PORT}/tcp are free."
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
    ufw allow ${WEB_PORT}/tcp
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
# Generate credentials
#############################################

SERVER_IP=$(public_ip)
ADMIN_USER="admin"
ADMIN_PASS=$(random_password)

#############################################
# Create compose
#############################################

create_compose(){
    # Проверка существующей установки
    if [[ -f "${WG_DIR}/docker-compose.yml" ]]; then
        warn "Existing installation found in ${WG_DIR}."
        read -p "Do you want to overwrite? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            die "Installation aborted by user."
        fi
        # Бэкап старого compose
        cp "${WG_DIR}/docker-compose.yml" "${WG_DIR}/docker-compose.yml.bak.$(date +%s)"
        log "Backup created."
    fi

    log "Creating docker-compose.yml..."
    cat > "${WG_DIR}/docker-compose.yml" <<EOF
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:15.3.0
    container_name: wg-easy
    restart: unless-stopped
    environment:
      - INIT_ENABLED=true
      - INIT_USERNAME=${ADMIN_USER}
      - INIT_PASSWORD=${ADMIN_PASS}
      - INIT_HOST=${SERVER_IP}
      - INIT_PORT=${WG_PORT}
      - INIT_DNS=${DNS}
    volumes:
      - ./data:/etc/wireguard
      - /lib/modules:/lib/modules:ro
    ports:
      - "${WG_PORT}:${WG_PORT}/udp"
      - "${WEB_PORT}:51821/tcp"
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
      - NET_RAW
    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:51821"]
      interval: 10s
      timeout: 5s
      retries: 8
      start_period: 60s
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
# Wait container (using healthcheck)
#############################################

wait_container(){
    log "Waiting for container to become healthy (up to ~120s)..."
    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if docker inspect wg-easy >/dev/null 2>&1; then
            local status
            status=$(docker inspect --format='{{.State.Health.Status}}' wg-easy 2>/dev/null || echo "starting")

            case "$status" in
                healthy)
                    log "Container is healthy."
                    return 0
                    ;;
                unhealthy)
                    warn "Container is unhealthy (healthcheck failing). Checking logs..."
                    docker logs --tail 50 wg-easy
                    die "Healthcheck failed: container is unhealthy."
                    ;;
                starting)
                    # Это нормально для первых секунд
                    sleep 2
                    ((attempt++))
                    continue
                    ;;
                *)
                    warn "Unknown health status: $status. Waiting..."
                    sleep 2
                    ((attempt++))
                    continue
                    ;;
            esac
        else
            warn "Container not yet created. Waiting..."
            sleep 2
            ((attempt++))
        fi
    done

    warn "Reached max attempts without becoming healthy."
    docker logs --tail 100 wg-easy
    die "Container failed to become healthy within timeout."
}

#############################################
# Wait Web UI (fallback if healthcheck fails)
#############################################

wait_web(){
    log "Checking Web UI availability (fallback check)..."
    local max_attempts=60
    local attempt=0

    while [ $attempt -lt $max_attempts ]; do
        if curl -fs "http://127.0.0.1:${WEB_PORT}" >/dev/null 2>&1; then
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
    cd "${WG_DIR}"
    docker compose up -d --force-recreate
    log "Container recreated without INIT_* variables."
}

#############################################
# Finish
#############################################

finish(){
    cat <<EOF

==============================================

Installation completed successfully

WireGuard Server
Host:
${SERVER_IP}

Web UI
http://${SERVER_IP}:${WEB_PORT}

Username:
${ADMIN_USER}

Password:
${ADMIN_PASS}

WireGuard Port:
${WG_PORT}/udp

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
    check_ports          # проверка портов перед запуском
    configure_firewall
    create_dirs
    create_compose       # включает проверку на существующую установку
    start_wireguard
    wait_container       # теперь ждём healthcheck
    wait_web             # дополнительная проверка
    cleanup_compose      # бэкап и --force-recreate
    finish
}

main "$@"
