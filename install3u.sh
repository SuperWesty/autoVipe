#!/bin/bash
# ============================================================
#  Установка: Nginx заглушка + SSL + 3X-UI
#  (без amnezia-wg-easy)
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
  + Nginx заглушка (без AWG)
EOF
echo -e "${NC}"

# ─── КОНФИГУРАЦИЯ ─────────────────────────────────────────
header "Конфигурация"

read -rp "$(echo -e "${CYAN}Домен (например: example.com):${NC} ")" DOMAIN
[ -z "$DOMAIN" ] && error "Домен не может быть пустым"

read -rp "$(echo -e "${CYAN}Email для Let's Encrypt:${NC} ")" LE_EMAIL
[ -z "$LE_EMAIL" ] && error "Email не может быть пустым"

read -rp "$(echo -e "${CYAN}Порт 3X-UI (по умолчанию: 54321):${NC} ")" PANEL_PORT
[ -z "$PANEL_PORT" ] && PANEL_PORT=54321

read -rp "$(echo -e "${CYAN}Настроить автобэкапы? [y/N]:${NC} ")" SETUP_BACKUPS

SERVER_IP=$(curl -s4 ifconfig.me 2>/dev/null || curl -s4 icanhazip.com 2>/dev/null)
info "IP сервера: ${BOLD}$SERVER_IP${NC}"

echo ""
echo -e "${YELLOW}Параметры установки:${NC}"
echo -e "  Домен:        ${BOLD}$DOMAIN${NC}"
echo -e "  Email:        ${BOLD}$LE_EMAIL${NC}"
echo -e "  Порт 3X-UI:   ${BOLD}$PANEL_PORT${NC}"
echo -e "  IP сервера:   ${BOLD}$SERVER_IP${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}Всё верно? Продолжить? [y/N]:${NC} ")" CONFIRM
[[ ! "$CONFIRM" =~ ^[Yy]$ ]] && echo "Отмена." && exit 0

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export NEEDRESTART_SUSPEND=1

# ─── ШАГ 1: СИСТЕМА ───────────────────────────────────────
header "Шаг 1: Обновление системы"
apt update -qq && apt upgrade -y -qq
apt install -y -qq curl wget ufw cron gnupg2 ca-certificates \
    lsb-release software-properties-common apt-transport-https \
    dnsutils sqlite3
log "Система обновлена"

# ─── ШАГ 2: ФАЙРВОЛ ───────────────────────────────────────
header "Шаг 2: Настройка файрвола (UFW)"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp  comment "SSH"
ufw allow 80/tcp  comment "HTTP"
ufw allow 443/tcp comment "HTTPS"
ufw allow $PANEL_PORT/tcp comment "3X-UI temp"
ufw --force enable
log "Файрвол настроен"

# ─── ШАГ 3: NGINX + ЗАГЛУШКА ──────────────────────────────
header "Шаг 3: Установка Nginx + сайт-заглушка"
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
        .dot { width:12px; height:12px; background:#00ff88; border-radius:50%;
               display:inline-block; margin-right:8px; animation:pulse 2s infinite; }
        @keyframes pulse { 0%,100%{opacity:1} 50%{opacity:.4} }
        .status { font-size:14px; color:#00ff88; margin-bottom:30px; }
        h1 { font-size:2.5rem; font-weight:700; margin-bottom:10px; }
        .sub { color:rgba(255,255,255,.5); font-size:1rem; margin-bottom:40px; }
        .grid { display:grid; grid-template-columns:1fr 1fr; gap:15px; margin-top:30px; }
        .card { background:rgba(255,255,255,.05); border-radius:10px; padding:15px;
                border:1px solid rgba(255,255,255,.08); }
        .label { font-size:11px; color:rgba(255,255,255,.4); text-transform:uppercase; }
        .value { font-size:1.1rem; font-weight:600; margin-top:5px; }
        footer { margin-top:40px; font-size:12px; color:rgba(255,255,255,.2); }
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
        setInterval(()=>{
            const d=Math.floor((Date.now()-s)/1000),m=Math.floor(d/60),h=Math.floor(m/60);
            document.getElementById('up').textContent=h>0?h+'h '+m%60+'m':m>0?m+'m '+d%60+'s':d+'s';
        },1000);
        const t=Date.now();
        fetch(location.href).then(()=>{document.getElementById('ms').textContent=(Date.now()-t)+'ms';});
    </script>
</body>
</html>
HTMLEOF

cat > /etc/nginx/sites-available/default << NGINXEOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name $DOMAIN;
    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}
NGINXEOF

rm -f /etc/nginx/sites-enabled/default
ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
nginx -t && systemctl reload nginx
log "Nginx и заглушка готовы"

# ─── ШАГ 4: SSL СЕРТИФИКАТ ────────────────────────────────
header "Шаг 4: SSL сертификат (Let's Encrypt)"
apt install -y -qq certbot python3-certbot-nginx

info "Проверяем DNS для $DOMAIN..."
DOMAIN_IP=$(dig +short "$DOMAIN" A 2>/dev/null | tail -1)
[ -z "$DOMAIN_IP" ] && error "$DOMAIN не резолвится! Добавь A-запись → $SERVER_IP"
if [ "$DOMAIN_IP" != "$SERVER_IP" ]; then
    warn "$DOMAIN → $DOMAIN_IP (ожидался $SERVER_IP)"
    read -rp "$(echo -e "${YELLOW}Продолжить? [y/N]:${NC} ")" DNS_CONFIRM
    [[ ! "$DNS_CONFIRM" =~ ^[Yy]$ ]] && error "Исправь DNS и запусти заново"
else
    log "$DOMAIN → $DOMAIN_IP ✔"
fi

certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos -m "$LE_EMAIL" --redirect
log "SSL сертификат получен"

# ─── ШАГ 5: УСТАНОВКА 3X-UI ──────────────────────────────
header "Шаг 5: Установка 3X-UI"
TMP_3XUI=$(mktemp /tmp/3xui_XXXX.sh)
curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh -o "$TMP_3XUI"
chmod +x "$TMP_3XUI"

info "Запускаем установщик (порт: $PANEL_PORT, SSL: certbot)..."
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
    read -rp "$(echo -e "${CYAN}Введи WebBasePath вручную (без слешей):${NC} ")" XRAY_BASE_PATH
fi
log "WebBasePath: /$XRAY_BASE_PATH/"

ufw delete allow $PANEL_PORT/tcp 2>/dev/null || true

# ─── ШАГ 6: ФИНАЛЬНЫЙ NGINX КОНФИГ ───────────────────────
header "Шаг 6: Финальная настройка Nginx"

cat > /etc/nginx/sites-available/main << NGINXEOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}

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

    location / {
        try_files \$uri \$uri/ =404;
    }

    location /$XRAY_BASE_PATH {
        proxy_pass         http://127.0.0.1:$PANEL_PORT;
        proxy_set_header   Host              \$host;
        proxy_set_header   X-Real-IP         \$remote_addr;
        proxy_set_header   X-Forwarded-For   \$proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto \$scheme;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade           \$http_upgrade;
        proxy_set_header   Connection        "upgrade";
    }

    location /$XRAY_BASE_PATH/ {
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
log "Nginx настроен"

# ─── ШАГ 7: БЭКАПЫ ───────────────────────────────────────
if [[ "$SETUP_BACKUPS" =~ ^[Yy]$ ]]; then
    header "Шаг 7: Автобэкапы"
    mkdir -p /root/backups/3xui

    cat > /usr/local/bin/backup-3xui.sh << 'BKEOF'
#!/bin/bash
DIR="/root/backups/3xui"; DATE=$(date +%Y%m%d_%H%M%S); FILE="$DIR/3xui_$DATE.tar.gz"
mkdir -p "$DIR"
tar -czf "$FILE" /usr/local/x-ui/db/ /usr/local/x-ui/bin/config.json /etc/x-ui/ 2>/dev/null
[ $? -eq 0 ] && echo "[$(date)] ✔ $FILE ($(du -sh "$FILE"|cut -f1))" && find "$DIR" -name "3xui_*.tar.gz" -mtime +7 -delete \
             || echo "[$(date)] ✘ Ошибка бэкапа 3X-UI"
BKEOF
    chmod +x /usr/local/bin/backup-3xui.sh

    (crontab -l 2>/dev/null; echo "0 3 * * * /usr/local/bin/backup-3xui.sh >> /var/log/backup-3xui.log 2>&1") | crontab -
    log "Бэкап 3X-UI настроен (ежедневно в 3:00)"

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
        log "Telegram бэкапы настроены"
    fi
fi

# ─── ИТОГ ─────────────────────────────────────────────────
header "✅ Установка завершена!"

echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  ДОСТУП К СЕРВИСАМ${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  🌐  Заглушка:  ${CYAN}https://$DOMAIN${NC}"
echo -e "  📊  3X-UI:     ${CYAN}https://$DOMAIN/$XRAY_BASE_PATH/${NC}"
echo -e "      Логин/пароль: смотри выше в выводе установщика"
echo -e "      Прямой порт $PANEL_PORT закрыт снаружи"
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD}  ПОЛЕЗНЫЕ КОМАНДЫ${NC}"
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo -e "  x-ui                   # управление 3X-UI"
echo -e "  x-ui settings          # текущие настройки"
echo -e "  systemctl status nginx"
[[ "$SETUP_BACKUPS" =~ ^[Yy]$ ]] && echo -e "  backup-3xui.sh         # ручной бэкап"
echo ""
echo -e "${GREEN}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
