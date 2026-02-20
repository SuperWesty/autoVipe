
#!/bin/bash
set -e

echo "🇩🇪 Установка немецкого сервера с Hiddify v4.0"
echo "═════════════════════════════════════════════"
echo ""

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info() { echo -e "${GREEN}[✓]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step() { echo -e "${BLUE}[»]${NC} $1"; }

[[ $EUID -ne 0 ]] && error "Запустите с правами root"

# Параметры
read -p "Доменное имя (germany.example.com): " DOMAIN
[[ -z "$DOMAIN" ]] && error "Домен обязателен!"

read -p "Email для Let's Encrypt: " EMAIL
[[ -z "$EMAIL" ]] && error "Email обязателен!"

read -p "Секретный путь для Hiddify [germanSecret456]: " ADMIN_SECRET
ADMIN_SECRET=${ADMIN_SECRET:-germanSecret456}

step "Шаг 1/9: Обновление системы..."
apt update -qq && apt upgrade -y -qq
info "Обновлено"

step "Шаг 2/9: Установка пакетов..."
apt install -y -qq curl wget nano git ufw wireguard \
  wireguard-tools qrencode nginx certbot \
  python3-certbot-nginx docker.io >/dev/null 2>&1
info "Пакеты установлены"

step "Шаг 3/9: Настройка системы..."
timedatectl set-timezone Europe/Berlin
cat >> /etc/sysctl.conf << EOF
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
EOF
sysctl -p >/dev/null 2>&1
info "Настроено"

INTERFACE=$(ip -br link show | grep -v lo | awk '{print $1}' | head -n1)
SERVER_IP=$(curl -4 -s ifconfig.me)
info "Интерфейс: $INTERFACE, IP: $SERVER_IP"

step "Шаг 4/9: Установка Hiddify..."

cat > /tmp/hiddify-config << EOF
1
$DOMAIN
$ADMIN_SECRET


n
8443
EOF

bash -c "$(curl -Lfo- https://raw.githubusercontent.com/hiddify/Hiddify-Manager/main/install.sh)" < /tmp/hiddify-config
rm /tmp/hiddify-config
sleep 10

if [ -f /opt/hiddify-manager/hiddify-panel/config.py ]; then
    sed -i 's/0.0.0.0/127.0.0.1/g' /opt/hiddify-manager/hiddify-panel/config.py 2>/dev/null || true
    systemctl restart hiddify-panel 2>/dev/null || true
fi

info "Hiddify установлен"

step "Шаг 5/9: AmneziaWG..."
mkdir -p /etc/wireguard/clients

wg genkey | tee /etc/wireguard/server-germany-private.key | \
  wg pubkey > /etc/wireguard/server-germany-public.key
wg genkey | tee /etc/wireguard/clients/client1-private.key | \
  wg pubkey > /etc/wireguard/clients/client1-public.key
wg genkey | tee /etc/wireguard/tunnel-germany-private.key | \
  wg pubkey > /etc/wireguard/tunnel-germany-public.key

SERVER_PRIVATE=$(cat /etc/wireguard/server-germany-private.key)
SERVER_PUBLIC=$(cat /etc/wireguard/server-germany-public.key)
CLIENT_PRIVATE=$(cat /etc/wireguard/clients/client1-private.key)
CLIENT_PUBLIC=$(cat /etc/wireguard/clients/client1-public.key)
TUNNEL_PRIVATE=$(cat /etc/wireguard/tunnel-germany-private.key)
TUNNEL_PUBLIC=$(cat /etc/wireguard/tunnel-germany-public.key)

cat > /etc/wireguard/wg2.conf << EOF
[Interface]
Address = 10.88.88.1/24
PrivateKey = $SERVER_PRIVATE
ListenPort = 51822
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

[Peer]
PublicKey = $CLIENT_PUBLIC
AllowedIPs = 10.88.88.2/32
PersistentKeepalive = 25
EOF

cat > /etc/wireguard/clients/client1-germany-direct.conf << EOF
[Interface]
PrivateKey = $CLIENT_PRIVATE
Address = 10.88.88.2/24
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

wg-quick up wg2 >/dev/null 2>&1
systemctl enable wg-quick@wg2 >/dev/null 2>&1
info "WireGuard настроен"

step "Шаг 6/9: MTProto..."
docker run -d --name mtproto --restart=always \
  -p 8888:8888 -v /opt/mtproto:/data \
  telegrammessenger/proxy:latest >/dev/null 2>&1
sleep 5
MTPROTO_LINK=$(docker logs mtproto 2>&1 | grep "tg://proxy" | head -1)
info "MTProto установлен"

step "Шаг 7/9: SSL..."
certbot --nginx -d $DOMAIN --non-interactive --agree-tos -m $EMAIL
info "SSL получен"

step "Шаг 8/9: Nginx..."

cat > /var/www/html/index.html << 'HTMLEOF'
<!DOCTYPE html>
<html><head><meta charset="UTF-8">
<title>Tech Solutions</title>
<style>
body{font-family:Arial;background:linear-gradient(135deg,#1e3c72,#2a5298);
margin:0;padding:0;min-height:100vh;display:flex;justify-content:center;align-items:center}
.container{background:white;padding:60px;border-radius:15px;
box-shadow:0 10px 40px rgba(0,0,0,0.2);text-align:center}
h1{color:#1e3c72}
.status{color:#28a745;font-size:1.3em;margin:20px 0}
</style></head>
<body><div class="container">
<h1>🌐 Tech Solutions</h1>
<p class="status">✓ Services Online</p>
<p>European Infrastructure | 24/7</p>
</div></body></html>
HTMLEOF

cat > /etc/nginx/sites-available/multihop-germany << NGINXEOF
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

    location / { root /var/www/html; }
    
    location ~ ^/(admin|api|sub|subscription|user|api-admin) {
        proxy_pass http://127.0.0.1:8443;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_read_timeout 300s;
    }
    
    location /mtproto {
        proxy_pass http://127.0.0.1:8888;
        proxy_http_version 1.1;
    }
}
NGINXEOF

cat >> /etc/nginx/nginx.conf << 'STREAMEOF'

stream {
    server {
        listen 443 udp reuseport;
        proxy_pass 127.0.0.1:51822;
        proxy_timeout 10s;
    }
}
STREAMEOF

ln -sf /etc/nginx/sites-available/multihop-germany /etc/nginx/sites-enabled/
rm -f /etc/nginx/sites-enabled/default
nginx -t && systemctl restart nginx
info "Nginx настроен"

step "Шаг 9/9: UFW..."
ufw --force reset >/dev/null 2>&1
ufw default deny incoming >/dev/null 2>&1
ufw default allow outgoing >/dev/null 2>&1
ufw allow 22/tcp >/dev/null 2>&1
ufw allow 80/tcp >/dev/null 2>&1
ufw allow 443 >/dev/null 2>&1
echo "y" | ufw enable >/dev/null 2>&1
info "UFW настроен"

cat > /root/germany-server-info.txt << INFOEOF
═══════════════════════════════════════════════════
GERMANY SERVER (Hiddify v4.0)
═══════════════════════════════════════════════════

Date: $(date)
IP: $SERVER_IP
Domain: $DOMAIN

HIDDIFY: https://$DOMAIN/$ADMIN_SECRET/admin/
MTPROTO: $MTPROTO_LINK
TUNNEL KEY: $TUNNEL_PUBLIC

WireGuard configs:
/etc/wireguard/clients/client1-germany-direct.conf

Следующие шаги:
1. Войдите в Hiddify панель
2. Создайте wg0 туннель с Москвой
3. Настройте маршрутизацию
INFOEOF

echo ""
echo "════════════════════════════════════════════"
echo -e "${GREEN}✅ НЕМЕЦКИЙ СЕРВЕР УСТАНОВЛЕН!${NC}"
echo "════════════════════════════════════════════"
echo ""
echo "🎨 Hiddify: https://$DOMAIN/$ADMIN_SECRET/admin/"
echo "📱 MTProto: $MTPROTO_LINK"
echo "🔑 Tunnel Key: $TUNNEL_PUBLIC"
echo ""
echo "🔐 QR-код Germany Direct:"
qrencode -t ansiutf8 < /etc/wireguard/clients/client1-germany-direct.conf
echo ""
echo "⚠️ Настройте туннель wg0 между серверами!"
