#!/bin/bash
set -e

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Проверка запуска от root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Пожалуйста, запустите скрипт с правами root (sudo ./install.sh)${NC}"
    exit 1
fi

echo -e "${GREEN}=== Установка WireGuard + Telegram Bot ===${NC}"

# Определение директории скрипта (корень репозитория)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/opt/wg-bot"

# 1. Загрузка переменных из .env, если он есть
if [ -f "$SCRIPT_DIR/.env" ]; then
    echo -e "${YELLOW}Загружаю переменные из .env...${NC}"
    set -a
    source "$SCRIPT_DIR/.env"
    set +a
else
    echo -e "${RED}Файл .env не найден! Скопируйте .env.example в .env и заполните переменные.${NC}"
    exit 1
fi

# 2. Проверка обязательных переменных
if [ -z "$TELEGRAM_BOT_TOKEN" ]; then
    echo -e "${RED}Ошибка: TELEGRAM_BOT_TOKEN не задан в .env${NC}"
    exit 1
fi

# 3. Определение публичного IP, если не задан явно
if [ -z "$SERVER_PUBLIC_IP" ] || [ "$SERVER_PUBLIC_IP" = "auto" ]; then
    echo -e "${YELLOW}Определяю публичный IP-адрес...${NC}"
    SERVER_PUBLIC_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || echo "")
    if [ -z "$SERVER_PUBLIC_IP" ]; then
        echo -e "${RED}Не удалось определить публичный IP. Укажите его в .env вручную.${NC}"
        exit 1
    fi
    echo -e "${GREEN}Публичный IP: $SERVER_PUBLIC_IP${NC}"
fi

# 4. Определение основного сетевого интерфейса
NETWORK_INTERFACE=$(ip route | grep default | awk '{print $5}' | head -n1)
if [ -z "$NETWORK_INTERFACE" ]; then
    NETWORK_INTERFACE="eth0"
    echo -e "${YELLOW}Не удалось определить интерфейс, использую 'eth0'${NC}"
fi
echo -e "${GREEN}Сетевой интерфейс: $NETWORK_INTERFACE${NC}"

# 5. Обновление системы и установка пакетов
echo -e "${YELLOW}Обновление пакетов и установка зависимостей...${NC}"
apt update && apt upgrade -y
apt install -y wireguard qrencode python3 python3-pip python3-venv git ufw iptables

# 6. Копирование файлов бота в INSTALL_DIR
echo -e "${YELLOW}Копирование файлов бота в $INSTALL_DIR...${NC}"
mkdir -p "$INSTALL_DIR"
cp -r "$SCRIPT_DIR/bot/"* "$INSTALL_DIR/"
cp "$SCRIPT_DIR/.env" "$INSTALL_DIR/.env"

# 7. Установка Python-зависимостей
echo -e "${YELLOW}Установка Python-зависимостей...${NC}"
cd "$INSTALL_DIR"
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
deactivate

# 8. Генерация ключей WireGuard
echo -e "${YELLOW}Генерация ключей WireGuard...${NC}"
mkdir -p /etc/wireguard
cd /etc/wireguard
wg genkey | tee server_private.key | wg pubkey > server_public.key
SERVER_PRIVATE_KEY=$(cat server_private.key)
SERVER_PUBLIC_KEY=$(cat server_public.key)

# 9. Создание конфигурации WireGuard из шаблона
echo -e "${YELLOW}Создание конфигурации WireGuard...${NC}"
cp "$SCRIPT_DIR/wireguard/wg0.conf" /etc/wireguard/wg0.conf
# Замена плейсхолдеров
sed -i "s|{{ WG_PORT }}|${WG_PORT:-51820}|g" /etc/wireguard/wg0.conf
sed -i "s|{{ SERVER_PRIVATE_KEY }}|${SERVER_PRIVATE_KEY}|g" /etc/wireguard/wg0.conf
sed -i "s|{{ NETWORK_INTERFACE }}|${NETWORK_INTERFACE}|g" /etc/wireguard/wg0.conf

# Установка прав
chmod 600 /etc/wireguard/wg0.conf
chmod 600 /etc/wireguard/server_private.key

# 10. Включение IP-форвардинга
echo -e "${YELLOW}Включение IP-форвардинга...${NC}"
sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sed -i 's/#net.ipv6.conf.all.forwarding=1/net.ipv6.conf.all.forwarding=1/' /etc/sysctl.conf
sysctl -p

# 11. Настройка UFW
echo -e "${YELLOW}Настройка фаервола...${NC}"
ufw allow ${WG_PORT:-51820}/udp comment 'WireGuard'
ufw allow OpenSSH
ufw --force enable

# 12. Запуск WireGuard
echo -e "${YELLOW}Запуск WireGuard...${NC}"
systemctl enable wg-quick@wg0
systemctl start wg-quick@wg0

# 13. Создание systemd сервиса для бота
echo -e "${YELLOW}Создание systemd сервиса для бота...${NC}"
cp "$SCRIPT_DIR/systemd/wg-bot.service" /etc/systemd/system/wg-bot.service
# Замена пути в сервисе, если он отличается от /opt/wg-bot
sed -i "s|/opt/wg-bot|$INSTALL_DIR|g" /etc/systemd/system/wg-bot.service

systemctl daemon-reload
systemctl enable wg-bot
systemctl start wg-bot

# 14. Вывод итоговой информации
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}Установка успешно завершена!${NC}"
echo -e "${GREEN}WireGuard работает на порту: ${WG_PORT:-51820}${NC}"
echo -e "${GREEN}Публичный ключ сервера: ${SERVER_PUBLIC_KEY}${NC}"
echo -e "${GREEN}Публичный IP сервера: ${SERVER_PUBLIC_IP}${NC}"
echo -e "${GREEN}Статус бота: $(systemctl is-active wg-bot)${NC}"
echo -e "${GREEN}Логи бота: journalctl -u wg-bot -f${NC}"
echo -e "${GREEN}========================================${NC}"
