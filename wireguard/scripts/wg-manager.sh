#!/bin/bash
# WireGuard Manager Script
# Поддерживает добавление/удаление клиентов, временные конфигурации, QR-коды и метаданные.

set -e

# --- Конфигурация (можно переопределить через переменные окружения) ---
WG_CONFIG="${WG_CONFIG:-/etc/wireguard/wg0.conf}"
SERVER_PUBLIC_KEY_FILE="${SERVER_PUBLIC_KEY_FILE:-/etc/wireguard/server_public.key}"
SERVER_PRIVATE_KEY_FILE="${SERVER_PRIVATE_KEY_FILE:-/etc/wireguard/server_private.key}"
META_FILE="${META_FILE:-/etc/wireguard/clients_meta.json}"
CLIENTS_DIR="${CLIENTS_DIR:-/root/wireguard-clients}"   # сюда будут сохраняться конфиги и QR-коды
QRENCODE_BIN=$(which qrencode)

# Параметры по умолчанию
DEFAULT_WG_PORT="${WG_PORT:-51820}"
DEFAULT_VPN_SUBNET_PREFIX="${VPN_SUBNET:-10.8.0.}"
DEFAULT_SERVER_IP="${DEFAULT_VPN_SUBNET_PREFIX}1"

# Публичный IP сервера (если не задан, попытаемся определить)
if [ -z "$SERVER_PUBLIC_IP" ] || [ "$SERVER_PUBLIC_IP" = "auto" ]; then
    SERVER_PUBLIC_IP=$(curl -s ifconfig.me || curl -s ipinfo.io/ip || echo "127.0.0.1")
fi

# Создаём директорию для клиентских конфигов
mkdir -p "$CLIENTS_DIR"

# --- Функции ---

# Генерация ключей для клиента
generate_keys() {
    local privkey=$(wg genkey)
    local pubkey=$(echo "$privkey" | wg pubkey)
    echo "$privkey $pubkey"
}

# Получение следующего свободного IP
get_next_ip() {
    local prefix="${1:-$DEFAULT_VPN_SUBNET_PREFIX}"
    local highest=0
    # Ищем все IP в конфиге и метаданных
    while read -r ip; do
        if [[ $ip =~ ^${prefix}([0-9]+)$ ]]; then
            local octet="${BASH_REMATCH[1]}"
            if [ "$octet" -gt "$highest" ]; then
                highest="$octet"
            fi
        fi
    done < <(grep -oE "${prefix}[0-9]+" "$WG_CONFIG" 2>/dev/null; cat "$META_FILE" 2>/dev/null | jq -r '.[].ip' 2>/dev/null)
    
    local next=$((highest + 1))
    # Минимум 2 (1 занят сервером)
    if [ "$next" -lt 2 ]; then
        next=2
    fi
    echo "${prefix}${next}"
}

# Чтение/создание метафайла
load_meta() {
    if [ ! -f "$META_FILE" ]; then
        echo "{}" > "$META_FILE"
    fi
    cat "$META_FILE"
}

save_meta() {
    echo "$1" > "$META_FILE"
}

# Добавление клиента
add_client() {
    local name="$1"
    local duration_seconds="$2"

    if [ -z "$name" ]; then
        echo "Ошибка: не указано имя клиента"
        exit 1
    fi

    # Проверка существования клиента
    if grep -q "# BEGIN_PEER $name" "$WG_CONFIG"; then
        echo "Ошибка: клиент с именем '$name' уже существует"
        exit 1
    fi

    # Генерация ключей и IP
    local keys=$(generate_keys)
    local privkey=$(echo "$keys" | cut -d' ' -f1)
    local pubkey=$(echo "$keys" | cut -d' ' -f2)
    local client_ip=$(get_next_ip "$DEFAULT_VPN_SUBNET_PREFIX")
    
    # Читаем публичный ключ сервера
    local server_pubkey=$(cat "$SERVER_PUBLIC_KEY_FILE")

        # Определяем Endpoint с учётом типа IP (IPv6 требует скобок)
    if [[ "$SERVER_PUBLIC_IP" =~ .*:.* ]]; then
        ENDPOINT="[$SERVER_PUBLIC_IP]:$DEFAULT_WG_PORT"
    else
        ENDPOINT="$SERVER_PUBLIC_IP:$DEFAULT_WG_PORT"
    fi

    # Создаём клиентский конфиг
    local conf_path="$CLIENTS_DIR/${name}.conf"
    cat > "$conf_path" <<EOF
[Interface]
PrivateKey = $privkey
Address = $client_ip/32
DNS = 1.1.1.1, 8.8.8.8
MTU = 1280

[Peer]
PublicKey = $server_pubkey
Endpoint = $ENDPOINT
AllowedIPs = 0.0.0.0/0, ::/0
PersistentKeepalive = 25
EOF

    # Генерируем QR-код в PNG
    local png_path="$CLIENTS_DIR/${name}.png"
    if [ -n "$QRENCODE_BIN" ]; then
        $QRENCODE_BIN -t PNG -o "$png_path" < "$conf_path"
    else
        echo "qrencode не найден, QR-код не будет создан"
    fi

    # Добавляем пира в конфиг сервера
    cat >> "$WG_CONFIG" <<EOF

# BEGIN_PEER $name
[Peer]
PublicKey = $pubkey
AllowedIPs = $client_ip/32
# END_PEER $name
EOF

    # Применяем изменения
    wg addconf wg0 <(echo "[Peer]" && echo "PublicKey = $pubkey" && echo "AllowedIPs = $client_ip/32") 2>/dev/null || wg syncconf wg0 <(wg-quick strip wg0)

    # Обновляем метаданные
    local meta=$(load_meta)
    local expires=0
    if [ "$duration_seconds" -gt 0 ]; then
        expires=$(($(date +%s) + duration_seconds))
        # Планируем удаление через at
        echo "systemctl restart wg-quick@wg0" | at now + "$duration_seconds" seconds 2>/dev/null || true
    fi
    meta=$(echo "$meta" | jq --arg name "$name" --arg ip "$client_ip" --argjson expires "$expires" \
        '.[$name] = {"ip": $ip, "expires": $expires}')
    save_meta "$meta"

    echo "Клиент $name добавлен с IP $client_ip"
    echo "Конфиг сохранён: $conf_path"
    if [ -f "$png_path" ]; then
        echo "QR-код сохранён: $png_path"
    fi
}

# Удаление клиента
delete_client() {
    local name="$1"
    if [ -z "$name" ]; then
        echo "Ошибка: не указано имя клиента"
        exit 1
    fi

    # Найти публичный ключ по имени в конфиге
    local pubkey=$(awk -v name="$name" '
        /^# BEGIN_PEER / {in_peer=0; if ($3==name) in_peer=1}
        in_peer && /^PublicKey = / {print $3; exit}
    ' "$WG_CONFIG")

    if [ -z "$pubkey" ]; then
        echo "Ошибка: клиент с именем '$name' не найден"
        exit 1
    fi

    # Удаляем секцию из конфига
    sed -i "/# BEGIN_PEER $name/,/# END_PEER $name/d" "$WG_CONFIG"

    # Удаляем из активного интерфейса
    wg set wg0 peer "$pubkey" remove 2>/dev/null || true

    # Удаляем файлы конфигов и QR
    rm -f "$CLIENTS_DIR/${name}.conf" "$CLIENTS_DIR/${name}.png"

    # Обновляем метаданные
    local meta=$(load_meta)
    meta=$(echo "$meta" | jq "del(.[\"$name\"])")
    save_meta "$meta"

    echo "Клиент $name удалён"
}

# Список клиентов (вывод JSON для API)
list_clients() {
    load_meta
}

# Статистика (wg show с именами)
show_stats() {
    wg show
}

# --- Основная логика ---
case "$1" in
    add)
        add_client "$2" 0
        ;;
    add-temp)
        add_client "$2" "$3"
        ;;
    del)
        delete_client "$2"
        ;;
    list)
        list_clients
        ;;
    stats)
        show_stats
        ;;
    *)
        echo "Использование: $0 {add|add-temp|del|list|stats} [name] [duration_seconds]"
        exit 1
        ;;
esac
