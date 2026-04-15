# Важное примечание: Установка на сервер только за пределами страны блокировки.

# 1. Клонируем репозиторий
git clone git clone https://github.com/SergeyIlins/wireguard-bot.git
cd wireguard-bot

# 2. Копируем шаблон .env и редактируем его
cp .env.example .env
nano .env   # вставляем свои TELEGRAM_BOT_TOKEN, ADMIN_IDS

# 3. Запускаем установку
chmod +x install.sh
sudo ./install.sh
