#!/bin/bash
# =============================================================================
# VPN Infrastructure Installer v4.0 (Interactive + Fixed Cron)
# С выбором шагов и проверкой установленных компонентов
# =============================================================================

set -e
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Проверка root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Run as root!${NC}"
    exit 1
fi

# Функция для вопроса Да/Нет
ask_yes_no() {
    while true; do
        read -p "$(echo -e "${YELLOW}$1 (y/n): ${NC}")" yn
        case $yn in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) echo "Please answer y or n.";;
        esac
    done
}

# Функция проверки установлен ли пакет
is_installed() {
    command -v "$1" &> /dev/null
}

echo -e "${BLUE}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║     VPN Infrastructure Installer v4.0                  ║${NC}"
echo -e "${BLUE}║     Interactive Mode + Fixed Cron                      ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

# =============================================================================
# ШАГ 1: CRON
# =============================================================================
echo -e "${BLUE}━━━ Шаг 1: CRON ━━━${NC}"
if is_installed crontab && systemctl is-active --quiet cron; then
    echo -e "${GREEN}✓ Cron уже установлен и запущен${NC}"
    SKIP_CRON=true
else
    echo -e "${YELLOW}⚠ Cron не найден или не запущен${NC}"
    SKIP_CRON=false
fi

if [ "$SKIP_CRON" = false ]; then
    if ask_yes_no "Установить и настроить Cron?"; then
        echo -e "${YELLOW}Установка cron...${NC}"
        apt update -qq
        apt install -y -qq cron

        systemctl enable --now cron

        # Проверка что crontab теперь доступен
        if ! is_installed crontab; then
            echo -e "${YELLOW}crontab не в PATH, пробуем альтернативу...${NC}"
            apt install -y -qq cron-daemon-common 2>/dev/null || true
        fi

        # Принудительное добавление в PATH если нужно
        if ! is_installed crontab; then
            export PATH="/usr/bin:/bin:$PATH"
            echo 'export PATH="/usr/bin:/bin:$PATH"' >> /root/.bashrc
        fi

        systemctl restart cron
        echo -e "${GREEN}✓ Cron установлен и запущен${NC}"
    else
        echo -e "${YELLOW}⊘ Пропущено${NC}"
    fi
fi
echo ""

# =============================================================================
# ШАГ 2: DOCKER
# =============================================================================
echo -e "${BLUE}━━━ Шаг 2: DOCKER ━━━${NC}"
if is_installed docker && systemctl is-active --quiet docker; then
    echo -e "${GREEN}✓ Docker уже установлен и запущен${NC}"
    SKIP_DOCKER=true
else
    echo -e "${YELLOW}⚠ Docker не найден или не запущен${NC}"
    SKIP_DOCKER=false
fi

if [ "$SKIP_DOCKER" = false ]; then
    if ask_yes_no "Установить Docker?"; then
        echo -e "${YELLOW}Установка Docker...${NC}"
        apt install -y -qq curl wget git socat apt-transport-https ca-certificates gnupg lsb-release
        curl -fsSL https://get.docker.com | sh
        systemctl enable --now docker
        usermod -aG docker root
        echo -e "${GREEN}✓ Docker установлен${NC}"
    else
        echo -e "${YELLOW}⊘ Пропущено${NC}"
    fi
fi
echo ""

# =============================================================================
# ШАГ 3: UFW (Firewall)
# =============================================================================
echo -e "${BLUE}━━━ Шаг 3: UFW (Firewall) ━━━${NC}"
if is_installed ufw; then
    echo -e "${GREEN}✓ UFW уже установлен${NC}"
    SKIP_UFW=true
else
    echo -e "${YELLOW}⚠ UFW не найден${NC}"
    SKIP_UFW=false
fi

if [ "$SKIP_UFW" = false ]; then
    if ask_yes_no "Установить и настроить UFW?"; then
        echo -e "${YELLOW}Настройка UFW...${NC}"
        apt install -y -qq ufw

        # Настройка портов
        read -p "Открыть порты WireGuard (51820, 31456)? (y/n): " open_wg
        ufw --force reset
        ufw allow 22/tcp comment 'SSH'
        ufw allow 80/tcp comment 'HTTP'
        ufw allow 443/tcp comment 'HTTPS/VPN/Reality'

        if [[ "$open_wg" =~ ^[Yy]$ ]]; then
            ufw allow 51820/udp comment 'WireGuard (Server Link)'
            ufw allow 31456/udp comment 'AmneziaWG (Client)'
            echo -e "${GREEN}✓ Порты WG открыты${NC}"
        else
            echo -e "${YELLOW}⚠ Порты WG закрыты (только 443)${NC}"
        fi

        ufw default deny incoming
        ufw default allow outgoing
        echo "y" | ufw enable
        echo -e "${GREEN}✓ UFW настроен${NC}"
    else
        echo -e "${YELLOW}⊘ Пропущено${NC}"
    fi
fi
echo ""

# =============================================================================
# ШАГ 4: БЭКАП-СИСТЕМА
# =============================================================================
echo -e "${BLUE}━━━ Шаг 4: Бэкап-система ━━━${NC}"
if [ -d "/root/backups/scripts" ] && [ -f "/root/backups/scripts/backup-hiddify.sh" ]; then
    echo -e "${GREEN}✓ Бэкап-система уже существует${NC}"
    SKIP_BACKUP=true
else
    echo -e "${YELLOW}⚠ Бэкап-система не найдена${NC}"
    SKIP_BACKUP=false
fi

if [ "$SKIP_BACKUP" = false ]; then
    if ask_yes_no "Настроить систему бэкапов?"; then
        echo -e "${YELLOW}Создание структуры бэкапов...${NC}"
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

        # Cron задачи (если cron установлен)
        if is_installed crontab; then
            (crontab -l 2>/dev/null | grep -v "backup-hiddify" | grep -v "backup-amnezia"; \
             echo "0 3 * * * /root/backups/scripts/backup-hiddify.sh"; \
             echo "0 4 * * * /root/backups/scripts/backup-amnezia-app.sh") | crontab -
            echo -e "${GREEN}✓ Cron-задачи добавлены${NC}"
        else
            echo -e "${YELLOW}⚠ Cron не установлен, задачи не добавлены${NC}"
        fi
    else
        echo -e "${YELLOW}⊘ Пропущено${NC}"
    fi
fi
echo ""

# =============================================================================
# ШАГ 5: HIDDIFY MANAGER
# =============================================================================
echo -e "${BLUE}━━━ Шаг 5: Hiddify Manager ━━━${NC}"
if [ -d "/opt/hiddify-manager" ] && [ -f "/opt/hiddify-manager/docker-compose.yml" ]; then
    echo -e "${GREEN}✓ Hiddify Manager уже установлен${NC}"
    echo -e "${YELLOW}Панель доступна по адресу: https://$(curl -s ifconfig.me):<порт>/admin${NC}"
    SKIP_HIDDIFY=true
else
    echo -e "${YELLOW}⚠ Hiddify Manager не найден${NC}"
    SKIP_HIDDIFY=false
fi

if [ "$SKIP_HIDDIFY" = false ]; then
    if ask_yes_no "Установить Hiddify Manager? (10-15 минут)"; then
        echo -e "${YELLOW}Запуск установки Hiddify...${NC}"
        echo -e "${RED}⚠ Не прерывайте процесс!${NC}"
        bash <(curl -L https://i.hiddify.com/release)
        echo -e "${GREEN}✓ Hiddify Manager установлен${NC}"
    else
        echo -e "${YELLOW}⊘ Пропущено${NC}"
    fi
fi
echo ""

# =============================================================================
# ФИНАЛ
# =============================================================================
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  ✅ Настройка завершена!                               ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  📊 Проверка сервисов:                                 ║${NC}"

# Проверка статусов
is_installed crontab && systemctl is-active --quiet cron \
    && echo -e "${GREEN}  ✓ Cron работает${NC}" \
    || echo -e "${RED}  ✗ Cron не работает${NC}"

is_installed docker && systemctl is-active --quiet docker \
    && echo -e "${GREEN}  ✓ Docker работает${NC}" \
    || echo -e "${RED}  ✗ Docker не работает${NC}"

is_installed ufw && ufw status | grep -q "Status: active" \
    && echo -e "${GREEN}  ✓ UFW активен${NC}" \
    || echo -e "${YELLOW}  ⚠ UFW не активен${NC}"

[ -d "/opt/hiddify-manager" ] \
    && echo -e "${GREEN}  ✓ Hiddify установлен${NC}" \
    || echo -e "${YELLOW}  ⚠ Hiddify не установлен${NC}"

echo -e "${GREEN}╠════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  📁 Бэкапы: /root/backups/                             ║${NC}"
echo -e "${GREEN}║  📜 Скрипты: /root/backups/scripts/                    ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"

# Финальная проверка crontab
if is_installed crontab; then
    echo -e "${YELLOW}📅 Текущие cron-задачи:${NC}"
    crontab -l 2>/dev/null || echo "  Нет задач"
fi
