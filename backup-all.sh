#!/bin/bash
# =============================================================================
# Universal Backup Script for VPN Infrastructure
# Hiddify + AmneziaWG + Configs + Upload to Cloud
# =============================================================================
# Usage: ./backup-all.sh [--encrypt] [--upload] [--help]
# =============================================================================

set -e

# Configuration
BACKUP_DIR="/root/backups"
DATE=$(date +%F_%H-%M)
HOSTNAME=$(hostname)
ENCRYPT=false
UPLOAD=false
TELEGRAM_NOTIFY=false

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --encrypt) ENCRYPT=true; shift ;;
        --upload) UPLOAD=true; shift ;;
        --telegram) TELEGRAM_NOTIFY=true; shift ;;
        --help)
            echo "Usage: $0 [--encrypt] [--upload] [--telegram]"
            echo "  --encrypt    Encrypt backups with age"
            echo "  --upload     Upload to configured remote (rclone)"
            echo "  --telegram   Send notification to Telegram"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Functions
log() {
    echo -e "[$(date '+%H:%M:%S')] $1"
}

notify_telegram() {
    if [ "$TELEGRAM_NOTIFY" = true ] && [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -s "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/sendMessage" \
            -d "chat_id=$TELEGRAM_CHAT_ID&text=$1" > /dev/null || true    fi
}

# Main
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     VPN Infrastructure Backup Script                  ║${NC}"
echo -e "${GREEN}║     Host: $HOSTNAME | Date: $DATE                     ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"
echo ""

mkdir -p "$BACKUP_DIR"/{hiddify,amnezia,full}

# 1. Hiddify Backup
log "📦 Backing up Hiddify Manager..."
if [ -d /opt/hiddify-manager ]; then
    cd /opt/hiddify-manager
    bash hiddify-panel/backup.sh create 2>/dev/null || true
    
    tar -czf "$BACKUP_DIR/hiddify/hiddify-full-$DATE.tar.gz" /opt/hiddify-manager/ 2>/dev/null
    
    if [ "$ENCRYPT" = true ]; then
        log "🔐 Encrypting Hiddify backup..."
        age -r "$AGE_PUBLIC_KEY" -o "$BACKUP_DIR/hiddify/hiddify-full-$DATE.tar.gz.age" \
            "$BACKUP_DIR/hiddify/hiddify-full-$DATE.tar.gz"
        rm "$BACKUP_DIR/hiddify/hiddify-full-$DATE.tar.gz"
    fi
    
    log "${GREEN}✓ Hiddify backup completed${NC}"
else
    log "${YELLOW}⚠ Hiddify not installed, skipping${NC}"
fi

# 2. AmneziaWG Backup
log "📦 Backing up AmneziaWG..."
AMNEZIA_VOLUMES=$(docker volume ls -q | grep -i amnezia 2>/dev/null || true)
if [ -n "$AMNEZIA_VOLUMES" ]; then
    for vol in $AMNEZIA_VOLUMES; do
        docker run --rm \
            -v "$vol":/source \
            -v "$BACKUP_DIR/amnezia":/backup \
            alpine tar czf "/backup/${vol}-$DATE.tar.gz" -C /source . 2>/dev/null || true
        log "  - Volume: $vol"
    done
    
    [ -d /opt/amnezia ] && cp -r /opt/amnezia "$BACKUP_DIR/amnezia/amnezia-config-$DATE" 2>/dev/null || true
    log "${GREEN}✓ AmneziaWG backup completed${NC}"
else
    log "${YELLOW}⚠ AmneziaWG not found, skipping${NC}"
fi
# 3. System Configs Backup
log "📦 Backing up system configs..."
mkdir -p "$BACKUP_DIR/full/etc-$DATE"
cp -r /etc/ufw "$BACKUP_DIR/full/etc-$DATE/" 2>/dev/null || true
cp -r /etc/nginx "$BACKUP_DIR/full/etc-$DATE/" 2>/dev/null || true
crontab -l > "$BACKUP_DIR/full/crontab-$DATE.txt" 2>/dev/null || true
tar -czf "$BACKUP_DIR/full/system-configs-$DATE.tar.gz" -C "$BACKUP_DIR/full" "etc-$DATE" crontab-$DATE.txt
rm -rf "$BACKUP_DIR/full/etc-$DATE" "$BACKUP_DIR/full/crontab-$DATE.txt"
log "${GREEN}✓ System configs backup completed${NC}"

# 4. Cleanup Old Backups
log "🧹 Cleaning up old backups (>30 days)..."
find "$BACKUP_DIR" -name "*.tar.gz" -mtime +30 -delete 2>/dev/null || true
find "$BACKUP_DIR" -name "*.tar.gz.age" -mtime +30 -delete 2>/dev/null || true
log "${GREEN}✓ Cleanup completed${NC}"

# 5. Upload to Cloud
if [ "$UPLOAD" = true ]; then
    log "☁️ Uploading to cloud storage..."
    if command -v rclone &> /dev/null; then
        rclone sync "$BACKUP_DIR" "remote:vpn-backups/$HOSTNAME" --exclude "*.log" || log "${YELLOW}⚠ Upload failed${NC}"
    else
        log "${YELLOW}⚠ rclone not installed, skipping upload${NC}"
    fi
fi

# 6. Summary
echo ""
echo -e "${GREEN}╔════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║     ✅ Backup Completed Successfully!                 ║${NC}"
echo -e "${GREEN}╠════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Location: $BACKUP_DIR                               ║${NC}"
echo -e "${GREEN}║  Size: $(du -sh "$BACKUP_DIR" | cut -f1)             ║${NC}"
echo -e "${GREEN}║  Files: $(find "$BACKUP_DIR" -name "*.tar.gz*" | wc -l) archives          ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════════════╝${NC}"

# Notification
MESSAGE="✅ Backup completed on $HOSTNAME\nSize: $(du -sh "$BACKUP_DIR" | cut -f1)\nDate: $DATE"
notify_telegram "$MESSAGE"

log "All done!"
