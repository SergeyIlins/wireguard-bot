#!/usr/bin/env python3
import logging
import httpx
import json
from datetime import datetime
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, BotCommand
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, MessageHandler, filters, ContextTypes

# --- Конфигурация ---
TELEGRAM_BOT_TOKEN = "8600570752:AAH17G84B_fpwSI6AhetUeYQiDAipRMqTvQ"
API_URL = "http://127.0.0.1:8000"

# Разрешённые пользователи (укажите ваш Telegram ID)
ALLOWED_USERS = {466305214}  # Замените на свой ID

# Читаем API токен
with open("/opt/wireguard-api/.api_token", "r") as f:
    API_TOKEN = f.read().strip()
# -------------------

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# Сопоставление текста кнопки -> секунды
DURATION_MAP = {
    "24 часа": 86400,
    "1 месяц": 2592000,
    "3 месяца": 7776000,
    "6 месяцев": 15552000,
    "12 месяцев": 31104000,
    "Постоянный": 0
}

# Функция проверки прав
def is_allowed(update: Update) -> bool:
    user_id = update.effective_user.id
    if user_id not in ALLOWED_USERS:
        logger.warning(f"Доступ запрещён для пользователя {user_id}")
        return False
    return True

async def call_api(endpoint: str, data: dict = None):
    async with httpx.AsyncClient(timeout=30.0) as client:
        headers = {"Authorization": f"Bearer {API_TOKEN}"}
        if data:
            response = await client.post(f"{API_URL}/{endpoint}", json=data, headers=headers)
        else:
            response = await client.get(f"{API_URL}/{endpoint}", headers=headers)
        response.raise_for_status()
        return response.json()

async def set_commands(app):
    await app.bot.set_my_commands([BotCommand("menu", "Показать главное меню"), BotCommand("id", "Узнать свой Telegram ID")])

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_allowed(update):
        await update.message.reply_text("⛔ У вас нет доступа к этому боту.")
        return
    await update.message.reply_text("Добро пожаловать! Используйте /menu для управления WireGuard.")

async def show_id(update: Update, context: ContextTypes.DEFAULT_TYPE):
    """Команда для получения своего Telegram ID"""
    user_id = update.effective_user.id
    await update.message.reply_text(f"Ваш Telegram ID: `{user_id}`", parse_mode="Markdown")

async def menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_allowed(update):
        await update.message.reply_text("⛔ Нет доступа.")
        return
    keyboard = [
        [InlineKeyboardButton("➕ Добавить клиента", callback_data="add_client")],
        [InlineKeyboardButton("❌ Удалить клиента", callback_data="del_client")],
        [InlineKeyboardButton("📋 Список клиентов", callback_data="list_clients")],
        [InlineKeyboardButton("📊 Статистика", callback_data="stats")]
    ]
    await update.message.reply_text("Главное меню:", reply_markup=InlineKeyboardMarkup(keyboard))

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_allowed(update):
        await update.callback_query.answer("⛔ Нет доступа", show_alert=True)
        return
    query = update.callback_query
    await query.answer()
    data = query.data

    if data == "add_client":
        keyboard = [
            [InlineKeyboardButton("🕒 24 часа", callback_data="dur_86400")],
            [InlineKeyboardButton("📅 1 месяц", callback_data="dur_2592000")],
            [InlineKeyboardButton("📅 3 месяца", callback_data="dur_7776000")],
            [InlineKeyboardButton("📅 6 месяцев", callback_data="dur_15552000")],
            [InlineKeyboardButton("📅 12 месяцев", callback_data="dur_31104000")],
            [InlineKeyboardButton("♾️ Постоянный", callback_data="dur_0")],
            [InlineKeyboardButton("◀️ Назад", callback_data="back")]
        ]
        await query.edit_message_text("Выберите срок:", reply_markup=InlineKeyboardMarkup(keyboard))
    elif data.startswith("dur_"):
        seconds = int(data.split("_")[1])
        context.user_data['duration'] = seconds
        for text, sec in DURATION_MAP.items():
            if sec == seconds:
                duration_text = text
                break
        else:
            duration_text = f"{seconds} сек"
        await query.edit_message_text(f"Вы выбрали: {duration_text}\nТеперь введите имя клиента (латиница, 3-20 символов, можно - и _):")
        context.user_data['awaiting_name'] = True
    elif data == "del_client":
        context.user_data['awaiting_delete'] = True
        await query.edit_message_text("Введите имя клиента для удаления:")
    elif data == "list_clients":
        try:
            res = await call_api("list_clients")
            clients = res.get("clients", {})
            if not clients:
                await query.edit_message_text("Нет клиентов.")
                return
            msg = "📋 *Список клиентов:*\n\n"
            for name, info in clients.items():
                expires = info.get("expires", 0)
                ip = info.get("ip", "?")
                if expires == 0:
                    expire_str = "♾️ постоянный"
                else:
                    expire_str = f"⏰ до {datetime.fromtimestamp(expires).strftime('%Y-%m-%d %H:%M')}"
                msg += f"• *{name}* — {expire_str} (IP: {ip})\n"
            await query.edit_message_text(msg, parse_mode="Markdown")
        except Exception as e:
            await query.edit_message_text(f"Ошибка: {e}")
    elif data == "stats":
        try:
            res = await call_api("stats")
            output = res.get("output", "")
            if len(output) > 4000:
                output = output[:3500] + "\n... (обрезано)"
            await query.edit_message_text(f"📊 *Статистика:*\n```\n{output}\n```", parse_mode="Markdown")
        except Exception as e:
            await query.edit_message_text(f"Ошибка: {e}")
    elif data == "back":
        keyboard = [
            [InlineKeyboardButton("➕ Добавить клиента", callback_data="add_client")],
            [InlineKeyboardButton("❌ Удалить клиента", callback_data="del_client")],
            [InlineKeyboardButton("📋 Список клиентов", callback_data="list_clients")],
            [InlineKeyboardButton("📊 Статистика", callback_data="stats")]
        ]
        await query.edit_message_text("Главное меню:", reply_markup=InlineKeyboardMarkup(keyboard))

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_allowed(update):
        await update.message.reply_text("⛔ Нет доступа.")
        return
    text = update.message.text.strip()
    if context.user_data.get('awaiting_name'):
        name = text
        import re
        if not re.match(r'^[a-zA-Z0-9_-]{3,20}$', name):
            await update.message.reply_text("Некорректное имя. Разрешены буквы, цифры, - и _. Длина 3-20. Попробуйте снова /menu")
            context.user_data['awaiting_name'] = False
            return
        duration = context.user_data.get('duration', 0)
        try:
            res = await call_api("add_client", {"name": name, "duration_seconds": duration})
            conf_path = res.get("conf_path")
            png_path = res.get("png_path")
            if conf_path:
                with open(conf_path, 'rb') as f:
                    await update.message.reply_document(document=f, filename=f"{name}.conf")
            if png_path:
                with open(png_path, 'rb') as f:
                    await update.message.reply_photo(photo=f, caption=f"QR-код для {name}")
            await update.message.reply_text(f"✅ Клиент {name} добавлен.")
        except Exception as e:
            await update.message.reply_text(f"❌ Ошибка: {e}")
        context.user_data['awaiting_name'] = False
        context.user_data.pop('duration', None)
    elif context.user_data.get('awaiting_delete'):
        name = text
        try:
            await call_api("delete_client", {"name": name})
            await update.message.reply_text(f"🗑️ Клиент {name} удалён.")
        except Exception as e:
            await update.message.reply_text(f"❌ Ошибка: {e}")
        context.user_data['awaiting_delete'] = False
    else:
        await update.message.reply_text("Используйте /menu для управления.")

def main():
    app = Application.builder().token(TELEGRAM_BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("menu", menu))
    app.add_handler(CommandHandler("id", show_id))
    app.add_handler(CallbackQueryHandler(button_handler))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))
    app.post_init = set_commands
    app.run_polling()

if __name__ == "__main__":
    main()