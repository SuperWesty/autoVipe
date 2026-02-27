#!/bin/bash
# ============================================================
#  Скрипт установки:
#    - Nginx (сайт-заглушка + SSL)
#    - 3X-UI (панель управления прокси)
#    - amnezia-wg-easy от w0rng (AmneziaWG + Web UI в Docker)
#    - Бэкапы обоих сервисов
#
#  Автор: сгенерировано Claude (Anthropic)
#  ОС: Ubuntu 22.04 / 24.04
# ============================================================

set -e

# ─── ЦВЕТА ────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
info()   { echo -e "${CYAN}[→]${NC} $1"; }
header() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"; 
           echo -e "${BOLD}${BLUE}  $1${NC}";
           echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}\n"; }

# ─── ПРОВЕРКА ROOT ────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  error "Запусти скрипт от root: sudo bash install.sh"
fi

# ─── БАННЕР ───────────────────────────────────────────────
clear
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
  ██████╗ ██╗  ██╗      ██╗   ██╗██╗
  ╚════██╗╚██╗██╔╝      ██║   ██║██║
   █████╔╝ ╚███╔╝ █████╗██║   ██║██║
   ╚═══██╗ ██╔██╗ ╚════╝██║   ██║██║
  ██████╔╝██╔╝ ██╗      ╚██████╔╝██║
  ╚═════╝ ╚═╝  ╚═╝       ╚═════╝ ╚═╝
  + Nginx заглушка + AmneziaWG Easy
EOF
echo -e "${NC}"

# ─── СБОР ДАННЫХ ──────────────────────────────────────────
header "Конфигурация"

read -rp "$(echo -e "${CYAN}Введи домен (например: example.com):${NC} ")" DOMAIN
[ -z "$DOMAIN" ] && error "Домен не может быть пустым"

read -rp "$(echo -e "${CYAN}Email для Let's Encrypt (для уведомлений):${NC} ")" LE_EMAIL
[ -z "$LE_EMAIL" ] && error "Email не может быть пустым"

read -rp "$(echo -e "${CYAN}Секретный путь к панели 3X-UI (например: myadmin):${NC} ")" PANEL_PATH
[ -z "$PANEL_PATH" ] && PANEL_PATH="secret$(shuf -i 1000-9999 -n 1)"

read -rp "$(echo -e "${CYAN}Порт 3X-UI (по умолчанию: 54321):${NC} ")" PANEL_PORT
[ -z "$PANEL_PORT" ] && PANEL_PORT=54321

read -rp "$(echo -e "${CYAN}Пароль для amnezia-wg-easy Web UI:${NC} ")" AWG_PASSWORD
[ -z "$AWG_PASSWORD" ] && error "Пароль для AWG не может быть пустым"

read -rp "$(echo -e "${CYAN}UDP порт AmneziaWG (по умолчанию: 51820):${NC} ")" AWG_PORT
[ -z "$AWG_PORT" ] && AWG_PORT=51820

read -rp "$(echo -e "${CYAN}Установить amnezia-wg-easy? [y/N]:${NC} ")" INSTALL_AWG
read -rp "$(echo -e "${CYAN}Настроить автобэкапы? [y/N]:${NC} ")" SETUP_BACKUPS

SERVER_IP=$(curl -s4 ifconfig.me || curl -s4 icanhazip.com)
info "Обнаружен IP сервера: ${BOLD}$SERVER_IP${NC}"

echo ""
echo -e "${YELLOW}Параметры установки:${NC}"
echo -e "  Домен:            ${BOLD}$DOMAIN${NC}"
echo -e "  Email:            ${BOLD}$LE_EMAIL${NC}"
echo -e "  Путь к панели:    ${BOLD}/$PANEL_PATH${NC}"
echo -e "  Порт 3X-UI:       ${BOLD}$PANEL_PORT${NC}"
echo -e "  IP сервера:       ${BOLD}$SERVER_IP${NC}"
echo -e "  AWG UDP порт:     ${BOLD}$AWG_PORT${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}Всё верно? Продолжить? [y/N]:${NC} ")" CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && echo "Отмена." && exit 0

# ─── ОБНОВЛЕНИЕ СИСТЕМЫ ───────────────────────────────────
header "Шаг 1: Обновление системы"
apt update -qq && apt upgrade -y -qq
apt install -y -qq curl wget ufw cron gnupg2 ca-certificates \
    lsb-release software-properties-common apt-transport-https
log "Система обновлена"

# ─── ФАЙРВОЛ ──────────────────────────────────────────────
header "Шаг 2: Настройка файрвола (UFW)"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp    comment "SSH"
ufw allow 80/tcp    comment "HTTP"
ufw allow 443/tcp   comment "HTTPS"
ufw allow $PANEL_PORT/tcp comment "3X-UI panel (только локально)"
if [[ "$INSTALL_AWG" =~ ^[Yy]$ ]]; then
  ufw allow $AWG_PORT/udp comment "AmneziaWG"
fi
ufw --force enable
log "Файрвол настроен"

# ─── NGINX ────────────────────────────────────────────────
header "Шаг 3: Установка Nginx + сайт-заглушка"
apt install -y -qq nginx

# Создаём красивую заглушку
mkdir -p /var/www/html
cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>My Server</title>
    <style>
        * { margin: 0; padding: 0; box-sizing: border-box; }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
            background: linear-gradient(135deg, #0f0c29, #302b63, #24243e);
            min-height: 100vh;
            display: flex;
            align-items: center;
            justify-content: center;
            color: #fff;
        }
        .container {
            text-align: center;
            padding: 60px 40px;
            background: rgba(255,255,255,0.05);
            border-radius: 20px;
            border: 1px solid rgba(255,255,255,0.1);
            backdrop-filter: blur(10px);
            max-width: 500px;
            width: 90%;
        }
        .status-dot {
            width: 12px; height: 12px;
            background: #00ff88;
            border-radius: 50%;
            display: inline-block;
            margin-right: 8px;
            animation: pulse 2s infinite;
        }
        @keyframes pulse {
            0%, 100% { opacity: 1; }
            50% { opacity: 0.4; }
        }
        .status { font-size: 14px; color: #00ff88; margin-bottom: 30px; }
        h1 { font-size: 2.5rem; font-weight: 700; margin-bottom: 10px; }
        .subtitle { color: rgba(255,255,255,0.5); font-size: 1rem; margin-bottom: 40px; }
        .info-grid {
            display: grid;
            grid-template-columns: 1fr 1fr;
            gap: 15px;
            margin-top: 30px;
        }
        .info-card {
            background: rgba(255,255,255,0.05);
            border-radius: 10px;
            padding: 15px;
            border: 1px solid rgba(255,255,255,0.08);
        }
        .info-card .label { font-size: 11px; color: rgba(255,255,255,0.4); text-transform: uppercase; }
        .info-card .value { font-size: 1.1rem; font-weight: 600; margin-top: 5px; }
        footer { margin-top: 40px; font-size: 12px; color: rgba(255,255,255,0.2); }
    </style>
</head>
<body>
    <div class="container">
        <div class="status"><span class="status-dot"></span>Server Online</div>
        <h1>🚀 Welcome</h1>
        <p class="subtitle">This server is operating normally.</p>
        <div class="info-grid">
            <div class="info-card">
                <div class="label">Status</div>
                <div class="value">✅ Active</div>
            </div>
            <div class="info-card">
                <div class="label">Uptime</div>
                <div class="value" id="uptime">—</div>
            </div>
            <div class="info-card">
                <div class="label">Protocol</div>
                <div class="value">HTTPS</div>
            </div>
            <div class="info-card">
                <div class="label">Response</div>
                <div class="value" id="resp">—</div>
            </div>
        </div>
        <footer>© 2025 My Server. All rights reserved.</footer>
    </div>
    <script>
        const start = Date.now();
        setInterval(() => {
            const s = Math.floor((Date.now()-start)/1000);
            const m = Math.floor(s/60), h = Math.floor(m/60);
            document.getElementById('uptime').textContent = 
                h > 0 ? h+'h '+m%60+'m' : m > 0 ? m+'m '+s%60+'s' : s+'s';
        }, 1000);
        const t = Date.now();
        fetch(location.href).then(()=>{
            document.getElementById('resp').textContent = (Date.now()-t)+'ms';
        });
    </script>
</body>
</html>
HTMLEOF

# Временный HTTP конфиг для получения сертификата
cat > /etc/nginx/sites-available/default << NGINXEOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $DOMAIN;
    root /var/www/html;
    index index.html;
    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINXEOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
log "Nginx установлен и заглушка настроена"

# ─── SSL СЕРТИФИКАТ ───────────────────────────────────────
header "Шаг 4: Получение SSL сертификата (Let's Encrypt)"
apt install -y -qq certbot python3-certbot-nginx

info "Получаем сертификат для $DOMAIN..."
certbot --nginx -d "$DOMAIN" \
    --non-interactive \
    --agree-tos \
    -m "$LE_EMAIL" \
    --redirect

log "SSL сертификат получен"

# ─── NGINX С ПРОКСИРОВАНИЕМ 3X-UI ────────────────────────
header "Шаг 5: Настройка Nginx с проксированием 3X-UI"

cat > /etc/nginx/sites-available/main << NGINXEOF
# Редирект HTTP → HTTPS
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

# Основной HTTPS сервер
server {
    listen 443 ssl;
    listen [::]:443 ssl;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;

    # Современные SSL настройки
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:CHACHA20;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;

    # Безопасность
    add_header Strict-Transport-Security "max-age=63072000" always;
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;

    # Заглушка — обычный сайт по умолчанию
    root /var/www/html;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }

    # ─── Секретный путь к панели 3X-UI ───────────────────
    location /$PANEL_PATH {
        proxy_pass         http://127.0.0.1:$PANEL_PORT;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }

    location /$PANEL_PATH/ {
        proxy_pass         http://127.0.0.1:$PANEL_PORT;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }
}
NGINXEOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/main /etc/nginx/sites-enabled/main

nginx -t && systemctl reload nginx
log "Nginx настроен с проксированием 3X-UI"

# ─── УСТАНОВКА 3X-UI ──────────────────────────────────────
header "Шаг 6: Установка 3X-UI"
info "Запускаем официальный установщик 3X-UI..."
info "⚠️  Установщик задаст вопросы — укажи порт ${BOLD}$PANEL_PORT${NC} и путь ${BOLD}/$PANEL_PATH${NC}"
echo ""
bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)

# Закрываем прямой внешний доступ к порту панели
# Панель теперь доступна только через nginx на 443
ufw delete allow $PANEL_PORT/tcp 2>/dev/null || true
log "3X-UI установлен"

# ─── DOCKER ───────────────────────────────────────────────
if [[ "$INSTALL_AWG" =~ ^[Yy]$ ]]; then
    header "Шаг 7: Установка Docker"
    if ! command -v docker &>/dev/null; then
        curl -fsSL https://get.docker.com | sh
        systemctl enable docker
        systemctl start docker
        log "Docker установлен"
    else
        log "Docker уже установлен"
    fi

    # ─── AMNEZIA-WG-EASY ──────────────────────────────────
    header "Шаг 8: Установка amnezia-wg-easy (w0rng)"

    # Генерируем bcrypt хеш пароля
    info "Генерируем bcrypt хеш пароля..."
    
    # Проверяем наличие python3 с bcrypt или htpasswd
    if python3 -c "import bcrypt" 2>/dev/null; then
        AWG_HASH=$(python3 -c "
import bcrypt, sys
password = sys.argv[1].encode()
hashed = bcrypt.hashpw(password, bcrypt.gensalt(rounds=12))
print(hashed.decode())
" "$AWG_PASSWORD")
    else
        pip3 install bcrypt -q 2>/dev/null || pip install bcrypt -q 2>/dev/null
        AWG_HASH=$(python3 -c "
import bcrypt, sys
password = sys.argv[1].encode()
hashed = bcrypt.hashpw(password, bcrypt.gensalt(rounds=12))
print(hashed.decode())
" "$AWG_PASSWORD")
    fi

    info "Хеш пароля сгенерирован"

    # Создаём директорию для данных
    mkdir -p /opt/amnezia-wg-easy

    # Создаём docker-compose.yml
    cat > /opt/amnezia-wg-easy/docker-compose.yml << COMPOSEEOF
version: "3"

services:
  amnezia-wg-easy:
    image: ghcr.io/w0rng/amnezia-wg-easy:latest
    container_name: amnezia-wg-easy
    restart: unless-stopped
    
    environment:
      - LANG=ru
      - WG_HOST=${SERVER_IP}
      - PASSWORD_HASH=${AWG_HASH}
      - PORT=51821
      - WG_PORT=${AWG_PORT}
      - WG_DEFAULT_DNS=1.1.1.1,8.8.8.8
      - WG_MTU=1420
      - WG_PERSISTENT_KEEPALIVE=25
      - WG_DEFAULT_ADDRESS=10.8.0.x
      - WG_ALLOWED_IPS=0.0.0.0/0,::/0
      - UI_CHART_TYPE=1
      # AmneziaWG параметры обфускации
      - AWG_Jc=4
      - AWG_Jmin=50
      - AWG_Jmax=1000
      - AWG_S1=30
      - AWG_S2=40
      - AWG_H1=2
      - AWG_H2=3
      - AWG_H3=4
      - AWG_H4=5
    
    volumes:
      - /opt/amnezia-wg-easy/data:/etc/wireguard
    
    ports:
      - "${AWG_PORT}:${AWG_PORT}/udp"
      - "51821:51821/tcp"
    
    cap_add:
      - NET_ADMIN
      - SYS_MODULE
    
    sysctls:
      - net.ipv4.conf.all.src_valid_mark=1
      - net.ipv4.ip_forward=1
    
    devices:
      - /dev/net/tun:/dev/net/tun
COMPOSEEOF

    # Запускаем контейнер
    cd /opt/amnezia-wg-easy
    docker compose up -d

    log "amnezia-wg-easy запущен"

    # Проксируем Web UI AWG через Nginx (добавляем location)
    info "Добавляем проксирование AWG Web UI в Nginx..."
    
    # Вставляем location для AWG в конфиг nginx перед закрывающей скобкой
    sed -i "/^}/{ /^}/!b; x; s/^//; x; /^[[:space:]]*location \//!{ H; $!d; }; $ { G; s/\n//; }; }" \
        /etc/nginx/sites-available/main 2>/dev/null || true

    # Добавляем location для AWG через temp файл
    python3 << PYEOF
content = open('/etc/nginx/sites-available/main').read()
awg_location = """
    # ─── AmneziaWG Easy Web UI ────────────────────────────
    location /awgui/ {
        proxy_pass         http://127.0.0.1:51821/;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }
"""
# Вставляем перед последним закрывающим } в последнем server блоке
last = content.rfind('}')
content = content[:last] + awg_location + content[last:]
open('/etc/nginx/sites-available/main', 'w').write(content)
print("OK")
PYEOF

    nginx -t && systemctl reload nginx
    log "AWG Web UI доступен через https://$DOMAIN/awgui/"
fi

# ─── БЭКАПЫ ───────────────────────────────────────────────
if [[ "$SETUP_BACKUPS" =~ ^[Yy]$ ]]; then
    header "Шаг 9: Настройка автобэкапов"

    mkdir -p /root/backups/{3xui,awgeasy}

    # Скрипт бэкапа 3X-UI
    cat > /usr/local/bin/backup-3xui.sh << 'BKEOF'
#!/bin/bash
BACKUP_DIR="/root/backups/3xui"
DATE=$(date +%Y%m%d_%H%M%S)
FILE="$BACKUP_DIR/3xui_$DATE.tar.gz"
KEEP_DAYS=7
mkdir -p "$BACKUP_DIR"
tar -czf "$FILE" \
    /usr/local/x-ui/db/ \
    /usr/local/x-ui/bin/config.json \
    /etc/x-ui/ \
    2>/dev/null
if [ $? -eq 0 ]; then
    echo "[$(date)] ✔ Бэкап 3X-UI: $FILE ($(du -sh "$FILE" | cut -f1))"
    find "$BACKUP_DIR" -name "3xui_*.tar.gz" -mtime +$KEEP_DAYS -delete
else
    echo "[$(date)] ✘ Ошибка бэкапа 3X-UI"
fi
BKEOF
    chmod +x /usr/local/bin/backup-3xui.sh

    # Скрипт бэкапа AWG Easy
    cat > /usr/local/bin/backup-awgeasy.sh << 'BKEOF'
#!/bin/bash
BACKUP_DIR="/root/backups/awgeasy"
DATE=$(date +%Y%m%d_%H%M%S)
FILE="$BACKUP_DIR/awg_$DATE.tar.gz"
KEEP_DAYS=7
mkdir -p "$BACKUP_DIR"
tar -czf "$FILE" \
    /opt/amnezia-wg-easy/ \
    2>/dev/null
if [ $? -eq 0 ]; then
    echo "[$(date)] ✔ Бэкап AWG Easy: $FILE ($(du -sh "$FILE" | cut -f1))"
    find "$BACKUP_DIR" -name "awg_*.tar.gz" -mtime +$KEEP_DAYS -delete
else
    echo "[$(date)] ✘ Ошибка бэкапа AWG Easy"
fi
BKEOF
    chmod +x /usr/local/bin/backup-awgeasy.sh

    # Cron задания
    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/backup-3xui.sh >> /var/log/backup-3xui.log 2>&1") | crontab -
    (crontab -l 2>/dev/null; echo "30 3 * * * /usr/local/bin/backup-awgeasy.sh >> /var/log/backup-awgeasy.log 2>&1") | crontab -

    log "Бэкапы настроены (каждый день в 3:00 и 3:30)"

    # Предлагаем настроить Telegram бэкапы
    read -rp "$(echo -e "${CYAN}Настроить отправку бэкапов в Telegram? [y/N]:${NC} ")" SETUP_TG
    if [[ "$SETUP_TG" =~ ^[Yy]$ ]]; then
        read -rp "$(echo -e "${CYAN}Bot Token (@BotFather):${NC} ")" TG_TOKEN
        read -rp "$(echo -e "${CYAN}Chat ID (получи через @userinfobot):${NC} ")" TG_CHAT_ID

        cat > /usr/local/bin/send-backup-tg.sh << TGEOF
#!/bin/bash
# Отправка файла в Telegram
BOT_TOKEN="$TG_TOKEN"
CHAT_ID="$TG_CHAT_ID"
FILE="\$1"
CAPTION="\${2:-Бэкап сервера: \$(date '+%d.%m.%Y %H:%M')}"

if [ ! -f "\$FILE" ]; then
    echo "Файл не найден: \$FILE"
    exit 1
fi

curl -s -F "chat_id=\$CHAT_ID" \
     -F "document=@\$FILE" \
     -F "caption=\$CAPTION" \
     "https://api.telegram.org/bot\$BOT_TOKEN/sendDocument" > /dev/null

echo "[+] Отправлено в Telegram: \$FILE"
TGEOF
        chmod +x /usr/local/bin/send-backup-tg.sh

        # Добавляем отправку в TG в скрипты бэкапа
        echo '/usr/local/bin/send-backup-tg.sh "$FILE" "3X-UI бэкап: $(date)"' >> /usr/local/bin/backup-3xui.sh
        echo '/usr/local/bin/send-backup-tg.sh "$FILE" "AWG Easy бэкап: $(date)"' >> /usr/local/bin/backup-awgeasy.sh

        log "Отправка бэкапов в Telegram настроена"
    fi
fi

# ─── ИТОГ ─────────────────────────────────────────────────
header "✅ Установка завершена!"

echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  ДОСТУП К СЕРВИСАМ${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  🌐  Сайт-заглушка:"
echo -e "      ${CYAN}https://$DOMAIN${NC}"
echo ""
echo -e "  📊  Панель 3X-UI:"
echo -e "      ${CYAN}https://$DOMAIN/$PANEL_PATH${NC}"
echo -e "      (прямой доступ по порту ${PANEL_PORT} закрыт)"
echo ""
if [[ "$INSTALL_AWG" =~ ^[Yy]$ ]]; then
echo -e "  🔒  AmneziaWG Easy Web UI:"
echo -e "      ${CYAN}https://$DOMAIN/awgui/${NC}"
echo -e "      Пароль: ${BOLD}$AWG_PASSWORD${NC}"
echo -e "      UDP порт WG: ${BOLD}$AWG_PORT${NC}"
echo ""
fi
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  СЛЕДУЮЩИЕ ШАГИ${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  1. Войди в 3X-UI и смени логин/пароль по умолчанию"
echo -e "  2. Создай inbound (VLESS+WS+TLS или VLESS+Reality)"
echo -e "  3. Укажи в 3X-UI пути к сертификатам:"
echo -e "     ${YELLOW}/etc/letsencrypt/live/$DOMAIN/fullchain.pem${NC}"
echo -e "     ${YELLOW}/etc/letsencrypt/live/$DOMAIN/privkey.pem${NC}"
if [[ "$INSTALL_AWG" =~ ^[Yy]$ ]]; then
echo -e "  4. В AWG Easy добавь пользователей и раздай QR-коды"
echo -e "     Клиент: приложение Amnezia (iOS/Android/Desktop)"
fi
echo ""
echo -e "${BOLD}  ПОЛЕЗНЫЕ КОМАНДЫ${NC}"
echo -e ""
echo -e "  x-ui                  # управление 3X-UI"
echo -e "  x-ui status           # статус сервиса"
echo -e "  systemctl status nginx"
if [[ "$INSTALL_AWG" =~ ^[Yy]$ ]]; then
echo -e "  docker ps             # статус контейнера AWG"
echo -e "  cd /opt/amnezia-wg-easy && docker compose logs -f"
fi
if [[ "$SETUP_BACKUPS" =~ ^[Yy]$ ]]; then
echo -e ""
echo -e "  /usr/local/bin/backup-3xui.sh     # ручной бэкап 3X-UI"
echo -e "  /usr/local/bin/backup-awgeasy.sh  # ручной бэкап AWG"
echo -e "  ls /root/backups/                 # список бэкапов"
fi
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
