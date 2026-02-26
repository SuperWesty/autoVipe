#!/bin/bash
# =============================================================================
# VPN Infrastructure Installer v3.1 (Fixed cron installation)
# Без лишнего Nginx, с гибкой настройкой портов + cron
# =============================================================================

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# НАСТРОЙКИ
OPEN_WG_PORTS=true  # Поставь false, если хочешь закрыть порты WG и использовать только 443

if [ "$EUID" -ne 0 ]; then echo -e "${RED}Run as root!${NC}"; exit 1; fi

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     VPN Infrastructure Installer v3.1                  ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"

# 1. Система + Docker + CRON
echo -e "${YELLOW}[1/5] Система + Docker + Cron...${NC}"
apt update && apt upgrade -y
apt install -y curl wget git socat ufw cron
systemctl enable --now cron
curl -fsSL https://get.docker.com | sh
systemctl enable --now docker
usermod -aG docker root
echo -e "${GREEN}✓ Docker и Cron готовы${NC}"

# 2. UFW (Безопасность)
echo -e "${YELLOW}[2/5] Настройка UFW...${NC}"
ufw --force reset
ufw allow 22/tcp comment 'SSH'
ufw allow 80/tcp comment 'HTTP'
ufw allow 443/tcp comment 'HTTPS/VPN/Reality'

if [ "$OPEN_WG_PORTS" = true ]; then
    ufw allow 51820/udp comment 'WireGuard (Server Link)'
    ufw allow 31456/udp comment 'AmneziaWG (Client)'
    echo -e "${GREEN}✓ Порты WG открыты (51820, 31456)${NC}"
else
    echo -e "${YELLOW}⚠ Порты WG закрыты (Режим только 443)${NC}"
fi

ufw default deny incoming
ufw default allow outgoing
echo "y" | ufw enable

# 3. Бэкап-система
echo -e "${YELLOW}[3/5] Система бэкапов...${NC}"
mkdir -p /root/backups/{hiddify,amnezia,scripts}
chmod 700 /root/backups

# Скрипт бэкапа Hiddify
cat > /root/backups/scripts/backup-hiddify.sh <<'SCRIPT'
#!/bin/bash
BACKUP_DIR="/root/backups/hiddify"
DATE=$(date +%F_%H-%M)
mkdir -p $BACKUP_DIR
cd /opt/hiddify-manager 2>/dev/null && bash hiddify-panel/backup.sh create 2>/dev/null || true
tar -czf $BACKUP_DIR/hiddify-full-$DATE.tar.gz /opt/hiddify-manager/ 2>/dev/null || true
find $BACKUP_DIR -name "*.tar.gz" -mtime +30 -delete
echo "[$(date)] Hiddify backup completed" >> /root/backups/cron.log
SCRIPT
chmod +x /root/backups/scripts/backup-hiddify.sh

# Скрипт бэкапа Amnezia
cat > /root/backups/scripts/backup-amnezia-app.sh <<'SCRIPT'
#!/bin/bash
BACKUP_DIR="/root/backups/amnezia"
DATE=$(date +%F_%H-%M)
mkdir -p $BACKUP_DIR
for vol in $(docker volume ls -q | grep -i amnezia 2>/dev/null); do
  docker run --rm -v $vol:/source -v $BACKUP_DIR:/backup alpine tar czf /backup/${vol}-$DATE.tar.gz -C /source . 2>/dev/null || true
done
find $BACKUP_DIR -name "*.tar.gz" -mtime +30 -delete
echo "[$(date)] Amnezia backup completed" >> /root/backups/cron.log
SCRIPT
chmod +x /root/backups/scripts/backup-amnezia-app.sh

# Cron - настройка задач
echo -e "${YELLOW}Настройка cron-задач...${NC}"
(crontab -l 2>/dev/null; echo "0 3 * * * /root/backups/scripts/backup-hiddify.sh") | crontab -
(crontab -l 2>/dev/null; echo "0 4 * * * /root/backups/scripts/backup-amnezia-app.sh") | crontab -
echo -e "${GREEN}✓ Cron-задачи добавлены (03:00 и 04:00)${NC}"

# Проверка cron
echo -e "${YELLOW}Проверка cron-задач:${NC}"
crontab -l

# 4. Hiddify Manager
echo -e "${YELLOW}[4/5] Установка Hiddify Manager...${NC}"
bash <(curl -L https://i.hiddify.com/release)

# 5. Финал
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ Установка завершена!                               ║${NC}"
echo -e "${GREEN}║  💡 Заглушку настраивай в панели Hiddify (Settings)   ║${NC}"
echo -e "${GREEN}║  📅 Cron-задачи: 03:00 (Hiddify), 04:00 (Amnezia)     ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
