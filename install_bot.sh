#!/bin/sh

# Функция для проверки наличия утилит
check_dependencies() {
    local missing=0
    for cmd in curl jq; do
        if ! command -v "$cmd" > /dev/null 2>&1; then
            echo "❌ Утилита $cmd не установлена."
            missing=1
        fi
    done
    if [ "$missing" -eq 1 ]; then
        echo "Установите необходимые утилиты и повторите попытку."
        exit 1
    fi
}

# Функция для запроса ввода данных
ask_for_input() {
    local prompt="$1"
    local default="$2"
    local input

    if [ -n "$default" ]; then
        prompt="$prompt (по умолчанию: $default): "
    else
        prompt="$prompt: "
    fi

    read -r -p "$prompt" input
    if [ -z "$input" ] && [ -n "$default" ]; then
        input="$default"
    fi
    echo "$input"
}

# Создание init.d-скрипта
create_initd_script() {
    local BOT_SCRIPT="$1"
    local LOG_FILE="$2"

    # Путь к init.d-скрипту
    INITD_SCRIPT="/opt/etc/init.d/domain_bot"

    cat <<EOF > "$INITD_SCRIPT"
#!/bin/sh /etc/rc.common

START=99
STOP=10

BOT_SCRIPT="$BOT_SCRIPT"
LOG_FILE="$LOG_FILE"

start() {
    echo "Запуск бота..."
    \$BOT_SCRIPT >> "\$LOG_FILE" 2>&1 &
}

stop() {
    echo "Остановка бота..."
    PID=\$(pidof domain_bot.sh)
    if [ -n "\$PID" ]; then
        kill "\$PID"
        echo "✅ Процесс domain_bot.sh остановлен."
    else
        echo "❌ Процесс domain_bot.sh не найден."
    fi
}

restart() {
    stop
    sleep 1
    start
}
EOF

    chmod +x "$INITD_SCRIPT"
    echo "✅ Скрипт domain_bot добавлен в /opt/etc/init.d/."

    # Добавление в автозагрузку
    if [ -d "/opt/etc/rc.d" ]; then
        ln -s "../init.d/domain_bot" "/opt/etc/rc.d/S99domain_bot"
        echo "✅ Бот добавлен в автозагрузку."
    else
        echo "❌ Папка /opt/etc/rc.d не найдена. Автозагрузка не настроена."
    fi
}

# Установка бота
install_bot() {
    echo "=== Установка Telegram-бота для управления доменами ==="

    # Запрос необходимой информации
    BOT_TOKEN=$(ask_for_input "Введите токен вашего бота")
    CHAT_ID=$(ask_for_input "Введите ваш chat_id")
    LOCAL_FILE=$(ask_for_input "Введите путь к файлу доменов" "/opt/etc/AdGuardHome/my-domains-list.conf")
    LOG_DIR=$(ask_for_input "Введите путь к папке для логов" "/opt/etc/AdGuardHome/script_logs")

    # Создание папки для логов
    mkdir -p "$LOG_DIR"
    LOG_FILE="$LOG_DIR/bot.log"

    # Создание файла скрипта бота
    BOT_SCRIPT="/opt/bin/domain_bot.sh"
    cat <<EOF > "$BOT_SCRIPT"
#!/bin/sh

# Конфигурация
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
LOCAL_FILE="$LOCAL_FILE"
LOG_FILE="$LOG_FILE"

# Логирование
log() {
    local MESSAGE="\$(date '+%Y-%m-%d %H:%M:%S') - \$*"
    echo "\$MESSAGE" >> "\$LOG_FILE"  # Запись в лог-файл
    echo "\$MESSAGE"                 # Вывод в терминал
}

# Отправка сообщения в Telegram
send_telegram_message() {
    local MESSAGE="\$1"
    curl -s -X POST "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{
            \"chat_id\": \"\$CHAT_ID\",
            \"text\": \"\$MESSAGE\",
            \"parse_mode\": \"Markdown\"
        }" >> "\$LOG_FILE"
}

# Добавление домена
add_domain() {
    local DOMAIN="\$1"
    if grep -qxF "\$DOMAIN" "\$LOCAL_FILE"; then
        send_telegram_message "❌ Домен *\$DOMAIN* уже существует в списке."
    else
        echo "\$DOMAIN" >> "\$LOCAL_FILE"
        send_telegram_message "✅ Домен *\$DOMAIN* успешно добавлен."
    fi
}

# Удаление домена
remove_domain() {
    local DOMAIN="\$1"
    if grep -qxF "\$DOMAIN" "\$LOCAL_FILE"; then
        sed -i "/^\$DOMAIN\$/d" "\$LOCAL_FILE"
        send_telegram_message "✅ Домен *\$DOMAIN* успешно удалён."
    else
        send_telegram_message "❌ Домен *\$DOMAIN* не найден в списке."
    fi
}

# Показать список доменов
list_domains() {
    if [ -s "\$LOCAL_FILE" ]; then
        DOMAINS=\$(cat "\$LOCAL_FILE" | tr '\n' ', ' | sed 's/, \$/\n/')
        send_telegram_message "📋 Список доменов:\n\$DOMAINS"
    else
        send_telegram_message "📋 Список доменов пуст."
    fi
}

# Обработка входящих сообщений
process_message() {
    local MESSAGE="\$1"
    local COMMAND=\$(echo "\$MESSAGE" | awk '{print \$1}')
    local ARG=\$(echo "\$MESSAGE" | awk '{print \$2}')

    case "\$COMMAND" in
        /start)
            send_telegram_message "👋 Привет! Я бот для управления доменами.\n\nДоступные команды:\n/add <domain> - добавить домен\n/remove <domain> - удалить домен\n/list - показать список доменов"
            ;;
        /add)
            if [ -z "\$ARG" ]; then
                send_telegram_message "❌ Укажите домен для добавления: /add <domain>"
            else
                add_domain "\$ARG"
            fi
            ;;
        /remove)
            if [ -z "\$ARG" ]; then
                send_telegram_message "❌ Укажите домен для удаления: /remove <domain>"
            else
                remove_domain "\$ARG"
            fi
            ;;
        /list)
            list_domains
            ;;
        *)
            # Игнорируем неизвестные команды
            return
            ;;
    esac
}

# Основной цикл бота
log "Бот запущен."
OFFSET=0
while true; do
    UPDATES=\$(curl -s -X POST "https://api.telegram.org/bot\$BOT_TOKEN/getUpdates" \
        -d "offset=\$OFFSET" \
        -d "timeout=60")

    # Обработка каждого обновления
    UPDATES_COUNT=\$(echo "\$UPDATES" | jq '.result | length')
    if [ "\$UPDATES_COUNT" -gt 0 ]; then
        echo "\$UPDATES" | jq -r '.result[] | @base64' | while read -r UPDATE; do
            UPDATE=\$(echo "\$UPDATE" | base64 -d)
            OFFSET=\$(echo "\$UPDATE" | jq '.update_id')
            MESSAGE=\$(echo "\$UPDATE" | jq -r '.message.text')
            CHAT_ID=\$(echo "\$UPDATE" | jq -r '.message.chat.id')

            if [ "\$CHAT_ID" = "\$CHAT_ID" ]; then
                process_message "\$MESSAGE"
            fi

            # Увеличиваем OFFSET, чтобы избежать повторной обработки
            OFFSET=\$((OFFSET + 1))
        done
    fi

    sleep 1
done
EOF

    # Установка прав на выполнение
    chmod +x "$BOT_SCRIPT"

    # Создание init.d-скрипта
    create_initd_script "$BOT_SCRIPT" "$LOG_FILE"

    # Запуск бота
    echo "Запуск бота..."
    /opt/etc/init.d/domain_bot start

    echo "=== Установка завершена ==="
    echo "Бот запущен и добавлен в автозагрузку."
    echo "Логи будут сохраняться в файл: $LOG_FILE"
}

# Обновление бота
update_bot() {
    echo "=== Обновление Telegram-бота ==="

    # Проверка, установлен ли бот
    if [ ! -f "/opt/bin/domain_bot.sh" ]; then
        echo "❌ Бот не установлен. Сначала выполните установку."
        return
    fi

    # Остановка текущего процесса бота
    /opt/etc/init.d/domain_bot stop

    # Удаление старого скрипта
    rm -f "/opt/bin/domain_bot.sh" && echo "✅ Старый скрипт бота удалён."

    # Установка новой версии
    install_bot
}

# Удаление бота
remove_bot() {
    echo "=== Удаление Telegram-бота ==="

    # Проверка, установлен ли бот
    if [ ! -f "/opt/bin/domain_bot.sh" ]; then
        echo "❌ Бот не установлен."
        return
    fi

    # Остановка текущего процесса бота
    /opt/etc/init.d/domain_bot stop

    # Удаление скрипта
    rm -f "/opt/bin/domain_bot.sh" && echo "✅ Скрипт бота удалён."

    # Удаление из автозагрузки
    if [ -f "/opt/etc/init.d/domain_bot" ]; then
        rm -f "/opt/etc/init.d/domain_bot"
        echo "✅ Скрипт domain_bot удалён из /opt/etc/init.d/."
    fi

    if [ -f "/opt/etc/rc.d/S99domain_bot" ]; then
        rm -f "/opt/etc/rc.d/S99domain_bot"
        echo "✅ Бот удалён из автозагрузки."
    fi

    echo "=== Удаление завершено ==="
}

# Основное меню
main_menu() {
    while true; do
        echo "=== Меню управления ботом ==="
        echo "1. Установить"
        echo "2. Обновить"
        echo "3. Удалить"
        echo "4. Выход"
        read -r -p "Выберите действие (1-4): " choice

        case "$choice" in
            1)
                install_bot
                ;;
            2)
                update_bot
                ;;
            3)
                remove_bot
                ;;
            4)
                echo "Выход."
                exit 0
                ;;
            *)
                echo "❌ Неверный выбор. Попробуйте снова."
                ;;
        esac
    done
}

# Проверка зависимостей
check_dependencies

# Запуск основного меню
main_menu
