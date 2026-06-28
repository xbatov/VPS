#!/bin/bash

set -e

echo "====================================="
echo " VPN Server Installer (WireGuard + wg-easy)"
echo "====================================="

# Проверка прав root
if [ "$EUID" -ne 0 ]; then
    echo "❌ Запустите скрипт от root (sudo)."
    exit 1
fi

# Запрос параметров
echo ""
read -p "Введите публичный IP сервера: " SERVER_IP
if [ -z "$SERVER_IP" ]; then
    echo "❌ IP не может быть пустым."
    exit 1
fi

read -s -p "Введите пароль для панели wg-easy: " WG_PASSWORD
echo ""
if [ -z "$WG_PASSWORD" ]; then
    echo "❌ Пароль не может быть пустым."
    exit 1
fi

# Обновление системы (с подтверждением)
echo ""
echo "Будет выполнено обновление пакетов (apt update && apt upgrade -y)."
read -p "Продолжить? (y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Обновление системы..."
    apt update
    apt upgrade -y
else
    echo "Обновление пропущено."
fi

# Установка необходимых пакетов
echo ""
echo "Установка необходимых пакетов..."
apt install -y \
    curl \
    wget \
    git \
    nano \
    ufw \
    ca-certificates

# Установка Docker, если ещё не установлен
if ! command -v docker &> /dev/null; then
    echo ""
    echo "Установка Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker
    systemctl start docker
else
    echo ""
    echo "Docker уже установлен, пропускаем."
fi

# Проверка, запущен ли Docker
if ! systemctl is-active --quiet docker; then
    echo "Запуск Docker..."
    systemctl start docker
fi

# Настройка UFW (сброс правил, но с предупреждением)
echo ""
echo "Настройка UFW (правила будут сброшены и пересозданы)."
read -p "Продолжить? (y/N): " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow 51820/udp
    ufw allow 51821/tcp
    ufw --force enable
else
    echo "Настройка UFW пропущена. Убедитесь, что нужные порты открыты вручную."
fi

# Включение IP-форвардинга
echo ""
echo "Включение IP Forward..."
cat > /etc/sysctl.d/99-wireguard.conf <<EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl --system

# Создание директории и файла docker-compose.yml
mkdir -p /opt/wg-easy
cd /opt/wg-easy

# Проверяем, не заняты ли порты
check_port() {
    if ss -tuln | grep -q ":$1 "; then
        echo "❌ Порт $1 уже занят. Запуск невозможен."
        exit 1
    fi
}
check_port 51820
check_port 51821

# Генерация docker-compose.yml (способ хранения пароля оставлен как есть)
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

# Запуск/обновление контейнера
echo ""
echo "Запуск wg-easy..."
if docker ps -a --format '{{.Names}}' | grep -q "^wg-easy$"; then
    echo "Контейнер wg-easy уже существует. Останавливаем и пересоздаём..."
    docker compose down
    docker compose pull
fi
docker compose up -d

# Вывод информации
echo ""
echo "======================================"
echo "✅ Установка завершена!"
echo "======================================"
echo ""
echo "🌐 Панель WireGuard:"
echo "   http://${SERVER_IP}:51821"
echo "   Пароль: ${WG_PASSWORD}"
echo ""
echo "📌 Для управления используйте:"
echo "   cd /opt/wg-easy && docker compose [up|down|logs|restart]"
echo ""
echo "======================================"
