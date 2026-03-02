#!/bin/bash
# ============================================================
#  Установка: Nginx заглушка + SSL + 3X-UI + amnezia-wg-easy
#  AWG Easy на поддомене ag.ДОМЕН с Basic Auth защитой
#  Подписки 3X-UI через /sub/ (порт 2096)
#  ОС: Ubuntu 22.04 / 24.04
# ============================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✘]${NC} $1"; exit 1; }
info()   { echo -e "${CYAN}[→]${NC} $1"; }
header() { echo -e "\n${BOLD}${BLUE}══════════════════════════════════════${NC}"
           echo -e "${BOLD}${BLUE}  $1${NC}"
           echo -e "${BOLD}${BLUE}══════════════════════════════════════${NC}\n"; }

[ "$EUID" -ne 0 ] && error "Запусти от root: sudo bash $0"

clear
echo -e "${BOLD}${CYAN}"
cat << 'EOF'
  ██████╗ ██╗  ██╗      ██╗   ██╗██╗
  ╚════██╗╚██╗██╔╝      ██║   ██║██║
   █████╔╝ ╚███╔╝ █████╗██║   ██║██║
   ╚═══██╗ ██╔██╗ ╚════╝██║   ██║██║
  ██████╔╝██╔╝ ██╗      ╚██████╔╝██║
  ╚═════╝ ╚═╝  ╚═╝       ╚═════╝ ╚═╝
  + Nginx + AmneziaWG Easy
EOF
echo -e "${NC}"

# ─── КОНФИГУРАЦИЯ ─────────────────────────────────────────
header "Конфигурация"

read -rp "$(echo -e "${CYAN}Основной домен (например: example.com):${NC} ")" DOMAIN
[ -z "$DOMAIN" ] && error "Домен не может быть пустым"
AWG_DOMAIN="ag.$DOMAIN"
info "Поддомен AWG Easy: ${BOLD}$AWG_DOMAIN${NC}"

read -rp "$(echo -e "${CYAN}Email для Let's Encrypt:${NC} ")" LE_EMAIL
[ -z "$LE_EMAIL" ] && error "Email не может быть пустым"

read -rp "$(echo -e "${CYAN}Порт 3X-UI (по умолчанию: 54321):${NC} ")" PANEL_PORT
[ -z "$PANEL_PORT" ] && PANEL_PORT=54321

read -rp "$(echo -e "${CYAN}Пароль для AWG Easy (вход в WG панель):${NC} ")" AWG_PASSWORD
[ -z "$AWG_PASSWORD" ] && error "Пароль AWG не может быть пустым"

read -rp "$(echo -e "${CYAN}UDP порт AmneziaWG (по умолчанию: 51820):${NC} ")" AWG_PORT
[ -z "$AWG_PORT" ] && AWG_PORT=51820

echo -e "${CYAN}Basic Auth для защиты страницы ag.$DOMAIN:${NC}"
read -rp "$(echo -e "${CYAN}  Логин (по умолчанию: admin):${NC} ")" AWG_AUTH_USER
[ -z "$AWG_AUTH_USER" ] && AWG_AUTH_USER="admin"
read -rsp "$(echo -e "${CYAN}  Пароль:${NC} ")" AWG_AUTH_PASS
echo ""
[ -z "$AWG_AUTH_PASS" ] && error "Пароль Basic Auth не может быть пустым"

read -rp "$(echo -e "${CYAN}Настроить автобэкапы? [y/N]:${NC} ")" SETUP_BACKUPS

SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com 2>/dev/null)
info "IP сервера: ${BOLD}$SERVER_IP${NC}"

echo ""
echo -e "${YELLOW}Параметры установки:${NC}"
echo -e "  Основной домен:  ${BOLD}$DOMAIN${NC}"
echo -e "  AWG домен:       ${BOLD}$AWG_DOMAIN${NC}"
echo -e "  Email:           ${BOLD}$LE_EMAIL${NC}"
echo -e "  Порт 3X-UI:      ${BOLD}$PANEL_PORT${NC}"
echo -e "  AWG UDP порт:    ${BOLD}$AWG_PORT${NC}"
echo -e "  AWG Auth логин:  ${BOLD}$AWG_AUTH_USER${NC}"
echo -e "  IP сервера:      ${BOLD}$SERVER_IP${NC}"
echo ""
warn "Убедись что оба домена указывают на $SERVER_IP:"
warn "  $DOMAIN → $SERVER_IP"
warn "  $AWG_DOMAIN → $SERVER_IP"
echo ""
read -rp "$(echo -e "${YELLOW}DNS настроен и всё верно? [y/N]:${NC} ")" CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && echo "Отмена." && exit 0

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# ─── ШАГ 1: СИСТЕМА ───────────────────────────────────────
header "Шаг 1: Обновление системы"
apt update -qq && apt upgrade -y -qq
apt install -y -qq curl wget ufw cron gnupg2 ca-certificates \
    lsb-release software-properties-common apt-transport-https \
    apache2-utils dnsutils sqlite3
log "Система обновлена"

# ─── ШАГ 2: ФАЙРВОЛ ───────────────────────────────────────
header "Шаг 2: Настройка файрвола"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp             comment "SSH"
ufw allow 80/tcp             comment "HTTP"
ufw allow 443/tcp            comment "HTTPS"
ufw allow $PANEL_PORT/tcp    comment "3X-UI temp"
ufw allow $AWG_PORT/udp      comment "AmneziaWG"
ufw allow 2096/tcp           comment "3X-UI subscription"
ufw --force enable
log "Файрвол настроен"

# ─── ШАГ 3: NGINX + ЗАГЛУШКА ──────────────────────────────
header "Шаг 3: Nginx + сайт-заглушка"
apt install -y -qq nginx

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
            min-height: 100vh; display: flex;
            align-items: center; justify-content: center; color: #fff;
        }
        .container {
            text-align: center; padding: 60px 40px;
            background: rgba(255,255,255,0.05); border-radius: 20px;
            border: 1px solid rgba(255,255,255,0.1);
            backdrop-filter: blur(10px); max-width: 500px; width: 90%;
        }
        .dot { width:12px;height:12px;background:#00ff88;border-radius:50%;
               display:inline-block;margin-right:8px;animation:pulse 2s infinite; }
        @keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
        .status{font-size:14px;color:#00ff88;margin-bottom:30px;}
        h1{font-size:2.5rem;font-weight:700;margin-bottom:10px;}
        .sub{color:rgba(255,255,255,.5);font-size:1rem;margin-bottom:40px;}
        .grid{display:grid;grid-template-columns:1fr 1fr;gap:15px;margin-top:30px;}
        .card{background:rgba(255,255,255,.05);border-radius:10px;padding:15px;
              border:1px solid rgba(255,255,255,.08);}
        .label{font-size:11px;color:rgba(255,255,255,.4);text-transform:uppercase;}
        .value{font-size:1.1rem;font-weight:600;margin-top:5px;}
        footer{margin-top:40px;font-size:12px;color:rgba(255,255,255,.2);}
    </style>
</head>
<body>
    <div class="container">
        <div class="status"><span class="dot"></span>Server Online</div>
        <h1>🚀 Welcome</h1>
        <p class="sub">This server is operating normally.</p>
        <div class="grid">
            <div class="card"><div class="label">Status</div><div class="value">✅ Active</div></div>
            <div class="card"><div class="label">Uptime</div><div class="value" id="up">—</div></div>
            <div class="card"><div class="label">Protocol</div><div class="value">HTTPS</div></div>
            <div class="card"><div class="label">Response</div><div class="value" id="ms">—</div></div>
        </div>
        <footer>© 2025 My Server. All rights reserved.</footer>
    </div>
    <script>
        const s=Date.now();
        setInterval(()=>{const d=Math.floor((Date.now()-s)/1000),m=Math.floor(d/60),h=Math.floor(m/60);
        document.getElementById('up').textContent=h>0?h+'h '+m%60+'m':m>0?m+'m '+d%60+'s':d+'s';},1000);
        const t=Date.now();fetch(location.href).then(()=>{document.getElementById('ms').textContent=(Date.now()-t)+'ms';});
    </script>
</body>
</html>
HTMLEOF

# Временный конфиг для certbot
cat > /etc/nginx/sites-available/default << TMPEOF
server {
    listen 80 default_server;
    server_name $DOMAIN $AWG_DOMAIN;
    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
TMPEOF
rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
# Увеличиваем bucket size для длинных доменов (поддомены типа ag.example.com)
if ! grep -q 'server_names_hash_bucket_size' /etc/nginx/nginx.conf; then
    sed -i '/http {/a\\tserver_names_hash_bucket_size 64;' /etc/nginx/nginx.conf
fi
nginx -t && systemctl reload nginx
log "Nginx и заглушка готовы"

# ─── ШАГ 4: SSL ───────────────────────────────────────────
header "Шаг 4: SSL сертификаты"
apt install -y -qq certbot python3-certbot-nginx

for CHECK_DOMAIN in "$DOMAIN" "$AWG_DOMAIN"; do
    info "Проверяем DNS для $CHECK_DOMAIN..."
    D_IP=$(dig +short "$CHECK_DOMAIN" A 2>/dev/null | tail -1)
    [ -z "$D_IP" ] && error "$CHECK_DOMAIN не резолвится! Добавь A-запись → $SERVER_IP"
    [ "$D_IP" != "$SERVER_IP" ] && warn "$CHECK_DOMAIN → $D_IP (ожидался $SERVER_IP)" || log "$CHECK_DOMAIN → $D_IP ✔"
done

certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$LE_EMAIL" --redirect
log "Сертификат для $DOMAIN получен"

certbot certonly --nginx -d "$AWG_DOMAIN" --non-interactive --agree-tos -m "$LE_EMAIL"
log "Сертификат для $AWG_DOMAIN получен"

# ─── ШАГ 5: 3X-UI ─────────────────────────────────────────
header "Шаг 5: Установка 3X-UI"
TMP_3XUI=$(mktemp /tmp/3xui_XXXX.sh)
curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o "$TMP_3XUI"
chmod +x "$TMP_3XUI"
info "Запускаем установщик (автоответы: порт $PANEL_PORT, SSL от certbot)..."
{
    echo "y"
    echo "$PANEL_PORT"
    echo "3"
    echo "$DOMAIN"
    echo "/etc/letsencrypt/live/$DOMAIN/fullchain.pem"
    echo "/etc/letsencrypt/live/$DOMAIN/privkey.pem"
} | bash "$TMP_3XUI"
rm -f "$TMP_3XUI"
sleep 3

info "Определяем WebBasePath..."
XRAY_BASE_PATH=$(x-ui settings 2>/dev/null | grep -oP '(?<=webBasePath: )[^\s]+' | tr -d '/')
if [ -z "$XRAY_BASE_PATH" ]; then
    XRAY_BASE_PATH=$(sqlite3 /usr/local/x-ui/db/x-ui.db \
        "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null | tr -d '/')
fi
if [ -z "$XRAY_BASE_PATH" ]; then
    warn "Не удалось определить WebBasePath автоматически"
    read -rp "$(echo -e "${CYAN}Введи WebBasePath (без слешей, из вывода выше):${NC} ")" XRAY_BASE_PATH
fi
log "WebBasePath: /$XRAY_BASE_PATH/"
ufw delete allow $PANEL_PORT/tcp 2>/dev/null || true

# ─── ШАГ 6: DOCKER ────────────────────────────────────────
header "Шаг 6: Docker"
if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker && systemctl start docker
    log "Docker установлен"
else
    log "Docker уже установлен"
fi

# ─── ШАГ 7: AMNEZIA-WG-EASY ──────────────────────────────
header "Шаг 7: amnezia-wg-easy (w0rng)"

info "Генерируем bcrypt хеш пароля AWG..."
AWG_HASH_RAW=$(htpasswd -nbB -C 10 admin "$AWG_PASSWORD" | cut -d: -f2)
[ -z "$AWG_HASH_RAW" ] && error "Не удалось сгенерировать bcrypt хеш"
# $$ в docker-compose.yml = $ в контейнере (docker compose экранирует переменные)
AWG_HASH=$(echo "$AWG_HASH_RAW" | sed 's/\$/\$\$/g')
log "Хеш пароля сгенерирован (длина: ${#AWG_HASH_RAW} символов)"

mkdir -p /opt/amnezia-wg-easy/data

# Сохраняем оригинальный хеш в файл для справки
echo "$AWG_HASH_RAW" > /opt/amnezia-wg-easy/.hash_reference
chmod 600 /opt/amnezia-wg-easy/.hash_reference

cat > /opt/amnezia-wg-easy/docker-compose.yml << COMPOSEEOF
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

cd /opt/amnezia-wg-easy && docker compose up -d
sleep 3

# Проверяем что хеш дошёл до контейнера целым
HASH_IN_CONTAINER=$(docker exec amnezia-wg-easy env 2>/dev/null | grep PASSWORD_HASH | cut -d= -f2-)
if [ "${#HASH_IN_CONTAINER}" -lt 50 ]; then
    warn "Хеш в контейнере выглядит обрезанным (${#HASH_IN_CONTAINER} символов вместо 60)"
    warn "Попробуй: awg-passwd.sh '$AWG_PASSWORD'"
else
    log "Хеш в контейнере корректный (${#HASH_IN_CONTAINER} символов)"
fi

# Basic Auth для защиты AWG панели через nginx
info "Создаём Basic Auth для AWG панели..."
htpasswd -cb /etc/nginx/.awg_htpasswd "$AWG_AUTH_USER" "$AWG_AUTH_PASS"
log "Basic Auth настроен (логин: $AWG_AUTH_USER)"

# Скрипт смены пароля AWG
cat > /usr/local/bin/awg-passwd.sh << 'AWGEOF'
#!/bin/bash
[ -z "$1" ] && echo "Использование: awg-passwd.sh НОВЫЙ_ПАРОЛЬ" && exit 1
RAW=$(htpasswd -nbB -C 10 admin "$1" | cut -d: -f2)
ESCAPED=$(echo "$RAW" | sed 's/\$/\$\$/g')
python3 -c "
import re, sys
c = open('/opt/amnezia-wg-easy/docker-compose.yml').read()
c = re.sub(r'PASSWORD_HASH=.*', 'PASSWORD_HASH=' + sys.argv[1], c)
open('/opt/amnezia-wg-easy/docker-compose.yml', 'w').write(c)
" "$ESCAPED"
echo "$RAW" > /opt/amnezia-wg-easy/.hash_reference
docker stop amnezia-wg-easy && docker rm amnezia-wg-easy
cd /opt/amnezia-wg-easy && docker compose up -d
sleep 3
HASH_LEN=$(docker exec amnezia-wg-easy env 2>/dev/null | grep PASSWORD_HASH | cut -d= -f2- | wc -c)
echo "[✔] Пароль обновлён. Хеш в контейнере: $HASH_LEN символов (норма: 61)"
AWGEOF
chmod +x /usr/local/bin/awg-passwd.sh
log "Скрипт смены пароля AWG: awg-passwd.sh НОВЫЙ_ПАРОЛЬ"

# ─── ШАГ 8: ФИНАЛЬНЫЙ NGINX ───────────────────────────────
header "Шаг 8: Финальная настройка Nginx"

cat > /etc/nginx/sites-available/main << NGINXEOF
server {
    listen 80;
    server_name $DOMAIN $AWG_DOMAIN;
    return 301 https://\$host\$request_uri;
}

# ── Основной домен: заглушка + 3X-UI + подписки ───────────
server {
    listen 443 ssl;
    server_name $DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:CHACHA20;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    add_header Strict-Transport-Security "max-age=63072000" always;

    root /var/www/html;
    index index.html;

    # Заглушка
    location / {
        try_files \$uri \$uri/ =404;
    }

    # 3X-UI панель (рандомный путь от установщика)
    location /$XRAY_BASE_PATH {
        proxy_pass         https://127.0.0.1:$PANEL_PORT;
        proxy_ssl_verify   off;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }

    location /$XRAY_BASE_PATH/ {
        proxy_pass         https://127.0.0.1:$PANEL_PORT;
        proxy_ssl_verify   off;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }

    # Подписки 3X-UI
    # В панели: Settings → Subscription → Sub Port: 2096, Sub Path: /sub/
    # Ссылка для клиента: https://$DOMAIN/sub/КЛЮЧ
    location /sub/ {
        proxy_pass         http://127.0.0.1:2096/sub/;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
    }
}

# ── AWG поддомен: чистый прокси + Basic Auth ──────────────
server {
    listen 443 ssl;
    server_name $AWG_DOMAIN;

    ssl_certificate     /etc/letsencrypt/live/$AWG_DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$AWG_DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:CHACHA20;
    ssl_prefer_server_ciphers off;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 1d;
    add_header Strict-Transport-Security "max-age=63072000" always;

    # Basic Auth — первый рубеж, скрывает сам факт существования панели
    auth_basic           "Protected";
    auth_basic_user_file /etc/nginx/.awg_htpasswd;

    location / {
        proxy_pass         http://127.0.0.1:51821;
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
log "Nginx настроен"

# ─── ШАГ 9: БЭКАПЫ ───────────────────────────────────────
if [[ "$SETUP_BACKUPS" =~ ^[Yy]$ ]]; then
    header "Шаг 9: Автобэкапы"
    mkdir -p /root/backups/{3xui,awgeasy}

    cat > /usr/local/bin/backup-3xui.sh << 'BKEOF'
#!/bin/bash
DIR="/root/backups/3xui"; DATE=$(date +%Y%m%d_%H%M%S); FILE="$DIR/3xui_$DATE.tar.gz"
mkdir -p "$DIR"
tar -czf "$FILE" /usr/local/x-ui/db/ /usr/local/x-ui/bin/config.json /etc/x-ui/ 2>/dev/null
[ $? -eq 0 ] \
    && echo "[$(date)] ✔ $FILE ($(du -sh "$FILE"|cut -f1))" \
    && find "$DIR" -name "3xui_*.tar.gz" -mtime +7 -delete \
    || echo "[$(date)] ✘ Ошибка бэкапа 3X-UI"
BKEOF
    chmod +x /usr/local/bin/backup-3xui.sh

    cat > /usr/local/bin/backup-awgeasy.sh << 'BKEOF'
#!/bin/bash
DIR="/root/backups/awgeasy"; DATE=$(date +%Y%m%d_%H%M%S); FILE="$DIR/awg_$DATE.tar.gz"
mkdir -p "$DIR"
tar -czf "$FILE" /opt/amnezia-wg-easy/ 2>/dev/null
[ $? -eq 0 ] \
    && echo "[$(date)] ✔ $FILE ($(du -sh "$FILE"|cut -f1))" \
    && find "$DIR" -name "awg_*.tar.gz" -mtime +7 -delete \
    || echo "[$(date)] ✘ Ошибка бэкапа AWG"
BKEOF
    chmod +x /usr/local/bin/backup-awgeasy.sh

    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/backup-3xui.sh >> /var/log/backup-3xui.log 2>&1") | crontab -
    (crontab -l 2>/dev/null; echo "30 3 * * * /usr/local/bin/backup-awgeasy.sh >> /var/log/backup-awgeasy.log 2>&1") | crontab -
    log "Бэкапы настроены (3:00 и 3:30 ежедневно)"

    read -rp "$(echo -e "${CYAN}Отправка бэкапов в Telegram? [y/N]:${NC} ")" SETUP_TG
    if [[ "$SETUP_TG" =~ ^[Yy]$ ]]; then
        read -rp "$(echo -e "${CYAN}Bot Token:${NC} ")" TG_TOKEN
        read -rp "$(echo -e "${CYAN}Chat ID:${NC} ")" TG_CHAT_ID
        cat > /usr/local/bin/send-backup-tg.sh << TGEOF
#!/bin/bash
BOT_TOKEN="$TG_TOKEN"; CHAT_ID="$TG_CHAT_ID"; FILE="\$1"
CAPTION="\${2:-Бэкап: \$(date '+%d.%m.%Y %H:%M')}"
[ ! -f "\$FILE" ] && echo "Файл не найден" && exit 1
curl -s -F "chat_id=\$CHAT_ID" -F "document=@\$FILE" -F "caption=\$CAPTION" \
    "https://api.telegram.org/bot\$BOT_TOKEN/sendDocument" > /dev/null
echo "[+] Отправлено: \$FILE"
TGEOF
        chmod +x /usr/local/bin/send-backup-tg.sh
        echo '/usr/local/bin/send-backup-tg.sh "$FILE" "3X-UI бэкап"' >> /usr/local/bin/backup-3xui.sh
        echo '/usr/local/bin/send-backup-tg.sh "$FILE" "AWG бэкап"'   >> /usr/local/bin/backup-awgeasy.sh
        log "Telegram бэкапы настроены"
    fi
fi

# ─── ИТОГ ─────────────────────────────────────────────────
header "✅ Установка завершена!"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  ДОСТУП К СЕРВИСАМ${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  🌐  Заглушка:     ${CYAN}https://$DOMAIN${NC}"
echo ""
echo -e "  📊  3X-UI панель: ${CYAN}https://$DOMAIN/$XRAY_BASE_PATH/${NC}"
echo -e "      Логин/пароль: смотри выше в выводе установщика"
echo ""
echo -e "  📋  Подписки:     ${CYAN}https://$DOMAIN/sub/КЛЮЧ_КЛИЕНТА${NC}"
echo -e "      Настройка в панели: Settings → Subscription"
echo -e "      Sub Port: 2096  |  Sub Path: /sub/"
echo ""
echo -e "  🔒  AWG Easy:     ${CYAN}https://$AWG_DOMAIN${NC}"
echo -e "      Basic Auth:   ${BOLD}$AWG_AUTH_USER${NC} / (пароль введён при установке)"
echo -e "      Пароль AWG:   ${BOLD}$AWG_PASSWORD${NC}"
echo -e "      UDP порт:     ${BOLD}$AWG_PORT${NC}"
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  ПОЛЕЗНЫЕ КОМАНДЫ${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  x-ui                        # управление 3X-UI"
echo -e "  awg-passwd.sh ПАРОЛЬ        # сменить пароль AWG"
echo -e "  ufw allow ПОРТ/tcp          # открыть порт для нового inbound"
echo -e "  docker ps                   # статус контейнера AWG"
echo -e "  docker logs amnezia-wg-easy # логи AWG"
echo -e "  systemctl status nginx"
[[ "$SETUP_BACKUPS" =~ ^[Yy]$ ]] && \
echo -e "  backup-3xui.sh              # бэкап 3X-UI" && \
echo -e "  backup-awgeasy.sh           # бэкап AWG"
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
