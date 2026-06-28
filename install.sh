#!/bin/bash

set -e

echo "====================================="
echo " VPN Server Installer "
echo "====================================="

if [ "$EUID" -ne 0 ]; then
    echo "Запустите от root"
    exit 1
fi

echo ""
read -p "Введите публичный IP сервера: " SERVER_IP
read -s -p "Введите пароль для панели wg-easy: " WG_PASSWORD
echo ""

echo ""
echo "Обновление системы..."
apt update
apt upgrade -y

echo ""
echo "Установка необходимых пакетов..."
apt install -y \
curl \
wget \
git \
nano \
ufw \
ca-certificates

echo ""
echo "Установка Docker..."
curl -fsSL https://get.docker.com | sh

systemctl enable docker
systemctl start docker

echo ""
echo "Настройка UFW..."

ufw --force reset

ufw default deny incoming
ufw default allow outgoing

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 51820/udp
ufw allow 51821/tcp

ufw --force enable

echo ""
echo "Включение IP Forward..."

cat >/etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF

sysctl --system

echo ""
echo "Создание директории wg-easy..."

mkdir -p /opt/wg-easy
cd /opt/wg-easy

cat > docker-compose.yml <<EOF
services:
  wg-easy:
    image: ghcr.io/wg-easy/wg-easy:latest

    container_name: wg-easy

    restart: unless-stopped

    environment:
      - LANG=ru
      - PASSWORD=${WG_PASSWORD}
      - WG_HOST=${SERVER_IP}

    volumes:
      - ./config:/etc/wireguard

    ports:
      - "51820:51820/udp"
      - "51821:51821/tcp"

    cap_add:
      - NET_ADMIN
      - SYS_MODULE

    sysctls:
      - net.ipv4.ip_forward=1
      - net.ipv4.conf.all.src_valid_mark=1
EOF

echo ""
echo "Запуск wg-easy..."

docker compose up -d

echo ""
echo "======================================"
echo "Установка завершена!"
echo "======================================"
echo ""
echo "Панель WireGuard:"
echo "http://${SERVER_IP}:51821"
echo ""
echo "Далее выполните:"
echo ""
echo "bash <(curl -Ls https://raw.githubusercontent.com/hiddify/hiddify-manager/main/install.sh)"
echo ""
echo "После установки Hiddify следуйте инструкциям установщика."
echo ""
echo "======================================"
