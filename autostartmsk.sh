#!/bin/bash
# ============================================
# СКРИПТ 1: Установка МОСКОВСКОГО сервера с Hiddify
# Версия: 4.1 (Исправлена установка Hiddify + авто-генерация секрета)
# ============================================

set -e

echo "🚀 Установка московского сервера с Hiddify Manager v4.1"
echo "═══════════════════════════════════════════════════════"
echo ""

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[✓]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "${BLUE}[»]${NC} $1"; }

[[ $EUID -ne 0 ]] && error "Запустите с правами root"

# Функция генерации случайного секрета
generate_secret() {
    # Генерируем 16 символов: буквы и цифры
    cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w 16 | head -n 1
}

# Параметры
echo "📝 Настройка параметров:"
echo ""
read -p "Доменное имя (moscow.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && error "Домен обязателен для Hiddify!"

read -p "Email для Let's Encrypt: " EMAIL
[[ -z "$EMAIL" ]] && error "Email обязателен!"

# Автоматическая генерация секретного пути
ADMIN_SECRET=$(generate_secret)
info "Автоматически сгенерирован секретный путь: $ADMIN_SECRET"
echo ""

read -p "Использовать этот секретный путь? (y/n, или введите свой): " SECRET_CHOICE
if [[ "$SECRET_CHOICE" != "y" ]] && [[ "$SECRET_CHOICE" != "Y" ]] && [[ ! -z "$SECRET_CHOICE" ]]; then
    ADMIN_SECRET="$SECRET_CHOICE"
    info "Используется ваш секретный путь: $ADMIN_SECRET"
fi

echo ""
warn "ВНИМАНИЕ: Hiddify требует чистую систему Ubuntu 22.04+"
read -p "Продолжить установку? (y/n): " CONFIRM
[[ "$CONFIRM" != "y" ]] && exit 0

step "Шаг 1/11: Обновление системы..."
apt update -qq
apt upgrade -y -qq
info "Система обновлена"

step "Шаг 2/11: Установка базовых пакетов..."
apt install -y -qq curl wget nano git ufw wireguard \
  wireguard-tools qrencode nginx certbot \
  python3-certbot-nginx net-tools >/dev/null 2>&1
info "Пакеты установлены"

step "Шаг 3/11: Настройка системы..."
timedatectl set-timezone Europe/Moscow
cat >> /etc/sysctl.conf << EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl -p >/dev/null 2>&1
info "IP forwarding включен"

step "Шаг 4/11: Определение интерфейса..."
INTERFACE=$(ip -br link show | grep -v lo | awk '{print $1}' | head -n1)
SERVER_IP=$(curl -4 -s ifconfig.me)
info "Интерфейс: $INTERFACE, IP: $SERVER_IP"

step "Шаг 5/11: Установка Hiddify Manager..."
warn "Это может занять 10-15 минут..."

# Правильная установка Hiddify (БЕЗ stdin!)
cd /tmp

# Скачиваем скрипт установки
wget -O hiddify-install.sh https://raw.githubusercontent.com/hiddify/Hiddify-Manager/main/install.sh

# Делаем исполняемым
chmod +x hiddify-install.sh

# Запускаем установку с переменными окружения
export ADMIN_SECRET="$ADMIN_SECRET"
export DOMAIN="$DOMAIN"

# Интерактивная установка (правильный способ)
bash hiddify-install.sh << EOF
$DOMAIN
$ADMIN_SECRET
$EMAIL
n
EOF

# Альтернативный метод если первый не сработал
if [ ! -d "/opt/hiddify-manager" ]; then
    warn "Пробуем альтернативный метод установки..."
    bash <(curl -Lfo- https://raw.githubusercontent.com/hiddify/Hiddify-Manager/main/install.sh)
fi

# Ждем запуска Hiddify
sleep 15

# Проверяем что Hiddify установлен
if [ -d "/opt/hiddify-manager" ]; then
    info "Hiddify Manager установлен"
    
    # Настраиваем на localhost (если возможно)
    if [ -f "/opt/hiddify-manager/hiddify-panel/hiddifypanel.py" ]; then
        # Пытаемся изменить конфигурацию на localhost
        find /opt/hiddify-manager -type f -name "*.py" -exec sed -i 's/0\.0\.0\.0/127.0.0.1/g' {} \; 2>/dev/null || true
        systemctl restart hiddify-panel 2>/dev/null || true
    fi
else
    error "Ошибка установки Hiddify! Проверьте логи."
fi

step "Шаг 6/11: Генерация ключей AmneziaWG..."
mkdir -p /etc/wireguard/clients

# Ключи для прямого подключения
wg genkey | tee /etc/wireguard/server-moscow-direct-private.key | \
  wg pubkey > /etc/wireguard/server-moscow-direct-public.key

wg genkey | tee /etc/wireguard/clients/client1-direct-private.key | \
  wg pubkey > /etc/wireguard/clients/client1-direct-public.key

# Ключи для multi-hop
wg genkey | tee /etc/wireguard/clients/client1-multihop-private.key | \
  wg pubkey > /etc/wireguard/clients/client1-multihop-public.key

SERVER_PRIVATE=$(cat /etc/wireguard/server-moscow-direct-private.key)
SERVER_PUBLIC=$(cat /etc/wireguard/server-moscow-direct-public.key)
CLIENT_DIRECT_PRIVATE=$(cat /etc/wireguard/clients/client1-direct-private.key)
CLIENT_DIRECT_PUBLIC=$(cat /etc/wireguard/clients/client1-direct-public.key)
CLIENT_MULTIHOP_PRIVATE=$(cat /etc/wireguard/clients/client1-multihop-private.key)
CLIENT_MULTIHOP_PUBLIC=$(cat /etc/wireguard/clients/client1-multihop-public.key)

info "Ключи сгенерированы"

step "Шаг 7/11: Настройка AmneziaWG wg1..."

cat > /etc/wireguard/wg1.conf << EOF
[Interface]
Address = 10.77.77.1/24
PrivateKey = $SERVER_PRIVATE
ListenPort = 51821

# AmneziaWG обфускация
Jc = 4
Jmin = 40
Jmax = 1000
S1 = 75
S2 = 88
H1 = 1234567890
H2 = 9876543210
H3 = 5555555555
H4 = 1111111111

PostUp = iptables -A FORWARD -i %i -j ACCEPT; iptables -t nat -A POSTROUTING -o $INTERFACE -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -t nat -D POSTROUTING -o $INTERFACE -j MASQUERADE

# Peer для прямого подключения
[Peer]
PublicKey = $CLIENT_DIRECT_PUBLIC
AllowedIPs = 10.77.77.2/32
PersistentKeepalive = 25

# Peer для multi-hop
[Peer]
PublicKey = $CLIENT_MULTIHOP_PUBLIC
AllowedIPs = 10.77.77.3/32
PersistentKeepalive = 25
EOF

wg-quick up wg1 >/dev/null 2>&1
systemctl enable wg-quick@wg1 >/dev/null 2>&1
info "AmneziaWG wg1 запущен"

step "Шаг 8/11: Создание клиентских конфигураций..."

# Direct конфигурация
cat > /etc/wireguard/clients/client1-moscow-direct.conf << EOF
[Interface]
PrivateKey = $CLIENT_DIRECT_PRIVATE
Address = 10.77.77.2/24
DNS = 8.8.8.8, 1.1.1.1

Jc = 4
Jmin = 40
Jmax = 1000
S1 = 75
S2 = 88
H1 = 1234567890
H2 = 9876543210
H3 = 5555555555
H4 = 1111111111

[Peer]
PublicKey = $SERVER_PUBLIC
Endpoint = $DOMAIN:443
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25
EOF

# Multi-Hop конфигурация
cat > /etc/wireguard/clients/client1-moscow-multihop.conf << EOF
[Interface]
PrivateKey = $CLIENT_MULTIHOP_PRIVATE
Address = 10.77.77.3/24
DNS = 8.8.8.8, 1.1.1.1

Jc = 4
Jmin = 40
Jmax = 1000
S1 = 75
S2 = 88
H1 = 1234567890
H2 = 9876543210
H3 = 5555555555
H4 = 1111111111

[Peer]
PublicKey = $SERVER_PUBLIC
Endpoint = $DOMAIN:443
AllowedIPs = 0.0.0.0/0
PersistentKeepalive = 25

# ЭТОТ ПРОФИЛЬ для MULTI-HOP через Германию
# Настройте маршрутизацию после создания туннеля
EOF

info "Клиентские конфигурации созданы"

step "Шаг 9/11: Получение SSL сертификата..."
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL
info "SSL сертификат получен"

step "Шаг 10/11: Настройка Nginx..."

# Фейковый сайт
cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Business Solutions</title>
    <style>
        body { 
            font-family: 'Segoe UI', sans-serif; 
            margin: 0; padding: 0;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            min-height: 100vh; display: flex;
            justify-content: center; align-items: center;
        }
        .container { 
            background: white; padding: 60px; 
            border-radius: 20px; 
            box-shadow: 0 20px 60px rgba(0,0,0,0.3);
            text-align: center; max-width: 700px;
        }
        h1 { 
            color: #333; font-size: 2.8em; margin-bottom: 20px;
            background: linear-gradient(135deg, #667eea, #764ba2);
            -webkit-background-clip: text;
            -webkit-text-fill-color: transparent;
        }
        .status { color: #28a745; font-size: 1.3em; font-weight: 600; margin: 30px 0; }
        .badge {
            display: inline-block;
            background: linear-gradient(135deg, #667eea, #764ba2);
            color: white; padding: 10px 25px;
            border-radius: 25px; margin-top: 20px; font-weight: 600;
        }
    </style>
</head>
<body>
    <div class="container">
        <h1>🏢 Business Solutions</h1>
        <p class="status">✓ All Systems Operational</p>
        <div class="badge">Enterprise Infrastructure</div>
        <p style="color: #666; margin-top: 30px;">
            Secure • Reliable • Scalable<br>
            Last check: <span id="time"></span>
        </p>
    </div>
    <script>
        document.getElementById('time').textContent = new Date().toLocaleString();
    </script>
</body>
</html>
HTMLEOF

# Nginx конфигурация
cat > /etc/nginx/sites-available/multihop-moscow << NGINXEOF
server {
    listen 80;
    server_name $DOMAIN;
    return 301 https://\$server_name\$request_uri;
}

server {
    listen 443 ssl http2;
    server_name $DOMAIN;

    ssl_certificate /etc/letsencrypt/live/$DOMAIN/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$DOMAIN/privkey.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;

    location / {
        root /var/www/html;
        index index.html;
    }

    # Hiddify Manager - секретный путь + admin/api пути
    location ~ ^/$ADMIN_SECRET/(admin|api|user) {
        proxy_pass http://127.0.0.1:9000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
        proxy_read_timeout 300s;
    }

    # Hiddify subscription пути
    location ~ ^/[a-zA-Z0-9_-]{8,}/.+ {
        proxy_pass http://127.0.0.1:9000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 300s;
    }
}
NGINXEOF

# Stream для WireGuard
if ! grep -q "stream {" /etc/nginx/nginx.conf; then
    cat >> /etc/nginx/nginx.conf << 'STREAMEOF'

stream {
    upstream wireguard_moscow {
        server 127.0.0.1:51821;
    }

    server {
        listen 443 udp reuseport;
        proxy_pass wireguard_moscow;
        proxy_timeout 10s;
    }
}
STREAMEOF
fi

ln -sf /etc/nginx/sites-available/multihop-moscow /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl restart nginx
systemctl enable nginx >/dev/null 2>&1
info "Nginx настроен"

step "Шаг 11/11: Настройка UFW..."
ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1
ufw allow 80/tcp comment 'HTTP' >/dev/null 2>&1
ufw allow 443 comment 'HTTPS' >/dev/null 2>&1
echo "y" | ufw enable >/dev/null 2>&1
info "UFW настроен (только 22, 80, 443)"

step "Создание скриптов маршрутизации..."

# Скрипт для Hiddify multi-hop
cat > /root/setup-multihop-hiddify.sh << 'SCRIPTEOF'
#!/bin/bash
sysctl -w net.ipv4.ip_forward=1
if ! grep -q "200 hiddify" /etc/iproute2/rt_tables; then
    echo "200 hiddify" >> /etc/iproute2/rt_tables
fi
ip rule del from 10.0.0.0/8 table hiddify 2>/dev/null || true
ip route flush table hiddify
ip route add default via 10.66.66.2 dev wg0 table hiddify
ip rule add from 10.0.0.0/8 table hiddify priority 100
echo "✅ Multi-hop через Hiddify настроен"
SCRIPTEOF

# Скрипт для AWG pure multi-hop
cat > /root/setup-multihop-awg-pure.sh << 'SCRIPTEOF'
#!/bin/bash
if ! grep -q "201 awg-multihop" /etc/iproute2/rt_tables; then
    echo "201 awg-multihop" >> /etc/iproute2/rt_tables
fi
ip rule del from 10.77.77.3/32 table awg-multihop 2>/dev/null || true
ip route flush table awg-multihop
ip route add default via 10.66.66.2 dev wg0 table awg-multihop
ip rule add from 10.77.77.3 table awg-multihop priority 101
echo "✅ Pure AWG multi-hop настроен"
SCRIPTEOF

chmod +x /root/setup-multihop-*.sh

# rc.local
cat > /etc/rc.local << 'RCEOF'
#!/bin/bash
sleep 15
/root/setup-multihop-hiddify.sh
/root/setup-multihop-awg-pure.sh
exit 0
RCEOF
chmod +x /etc/rc.local

# Сохранение информации
cat > /root/moscow-server-info.txt << INFOEOF
═══════════════════════════════════════════════════
MOSCOW SERVER INFORMATION (Hiddify v4.1)
═══════════════════════════════════════════════════

Installation Date: $(date)
Server IP: $SERVER_IP
Domain: $DOMAIN

═══ HIDDIFY MANAGER ═══
URL: https://$DOMAIN/$ADMIN_SECRET/admin/
Секретный путь: $ADMIN_SECRET

⚠️ ВАЖНО! СОХРАНИТЕ СЕКРЕТНЫЙ ПУТЬ!
Без него вы не сможете войти в панель!

Первый вход:
1. Откройте: https://$DOMAIN/$ADMIN_SECRET/admin/
2. Создайте admin аккаунт
3. Настройте пользователей

═══ ОТКРЫТЫЕ ПОРТЫ (UFW) ═══
22/tcp  - SSH
80/tcp  - HTTP
443     - HTTPS (Hiddify, WireGuard, Web)

═══ AMNEZIAWG KEYS ═══
Server Public:   $SERVER_PUBLIC
Client Direct:   $CLIENT_DIRECT_PUBLIC
Client MultiHop: $CLIENT_MULTIHOP_PUBLIC

═══ КЛИЕНТСКИЕ КОНФИГУРАЦИИ ═══
Moscow Direct:   /etc/wireguard/clients/client1-moscow-direct.conf
Moscow MultiHop: /etc/wireguard/clients/client1-moscow-multihop.conf

═══ СЛЕДУЮЩИЕ ШАГИ ═══
1. Войдите в Hiddify: https://$DOMAIN/$ADMIN_SECRET/admin/
2. Создайте пользователей
3. Настройте немецкий сервер
4. Создайте туннель wg0
5. Запустите скрипты маршрутизации

═══ ВАРИАНТЫ ПОДКЛЮЧЕНИЯ ═══
1. Hiddify - через subscription link из панели
2. AWG Direct - QR-код ниже
3. AWG Pure MultiHop - QR-код (после туннеля)

INFOEOF

echo ""
echo "════════════════════════════════════════════════════"
echo -e "${GREEN}✅ МОСКОВСКИЙ СЕРВЕР УСТАНОВЛЕН!${NC}"
echo "════════════════════════════════════════════════════"
echo ""
echo "📋 Информация: /root/moscow-server-info.txt"
echo ""
echo "🎨 Hiddify Panel:"
echo -e "   ${YELLOW}https://$DOMAIN/$ADMIN_SECRET/admin/${NC}"
echo ""
echo -e "${RED}⚠️  ВАЖНО! СОХРАНИТЕ СЕКРЕТНЫЙ ПУТЬ:${NC}"
echo -e "   ${GREEN}$ADMIN_SECRET${NC}"
echo ""
echo "🔐 QR-коды AmneziaWG:"
echo ""
echo "Moscow Direct:"
qrencode -t ansiutf8 < /etc/wireguard/clients/client1-moscow-direct.conf
echo ""
echo "Moscow MultiHop (настроить после туннеля):"
qrencode -t ansiutf8 < /etc/wireguard/clients/client1-moscow-multihop.conf
echo ""
echo "📝 Скопируйте и сохраните информацию выше!"
echo ""
echo "⏭️  Следующие шаги:"
echo "1. Откройте панель Hiddify"
echo "2. Создайте admin пользователя"
echo "3. Настройте немецкий сервер"
echo "4. Создайте туннель wg0"
echo ""
