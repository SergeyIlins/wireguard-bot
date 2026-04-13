# 1. Клонируем репозиторий
git clone git clone https://github.com/SergeyIlins/wireguard-bot.git

cd wireguard-bot

# 2. Копируем шаблон .env и редактируем его
cp .env.example .env
nano .env   # вставляем BOT_TOKEN, ALLOWED_TELEGRAM_IDS и т.д.

# 3. Запускаем установку
sudo ./install.sh
