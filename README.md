# 1. Клонируем репозиторий
git clone https://github.com/yourusername/wireguard-bot-deploy.git
cd wireguard-bot-deploy

# 2. Копируем шаблон .env и редактируем его
cp .env.example .env
nano .env   # вставляем BOT_TOKEN, ADMIN_IDS и т.д.

# 3. Запускаем установку
sudo ./install.sh