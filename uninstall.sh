#!/bin/bash
# ==============================================================================
# Script Uninstalasi AutoLogin Captive PENS
# ==============================================================================

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] Harap jalankan script ini dengan sudo:${NC}"
    echo "  sudo ./uninstall.sh"
    exit 1
fi

echo -e "${YELLOW}Menghentikan dan menonaktifkan service...${NC}"
systemctl stop captive.service 2>/dev/null || true
systemctl disable captive.service 2>/dev/null || true

systemctl stop captive-bot.service 2>/dev/null || true
systemctl disable captive-bot.service 2>/dev/null || true

echo -e "${YELLOW}Menghapus file service...${NC}"
rm -f /etc/systemd/system/captive.service
rm -f /etc/systemd/system/captive-bot.service
systemctl daemon-reload

echo -e "${YELLOW}Menghapus binary skrip di /usr/local/bin/...${NC}"
rm -f /usr/local/bin/captive.sh
rm -f /usr/local/bin/captive_v2_baru.sh
rm -f /usr/local/bin/telegram_bot_listener.sh

echo -e "${GREEN}✓ Layanan dan skrip berhasil dicopot.${NC}"

read -r -p "Apakah Anda ingin menghapus file konfigurasi & riwayat log (/etc/captive dan /var/local/captive*)? [y/N]: " CONFIRM
if [[ "$CONFIRM" =~ ^[yY]$ ]]; then
    rm -rf /etc/captive
    rm -f /var/local/captive_state.txt /var/local/rekap_mingguan.txt /var/local/last_notified.txt /var/local/captive_session.txt /var/local/captive_cookies.txt
    echo -e "${GREEN}✓ Konfigurasi dan file log berhasil dibersihkan.${NC}"
else
    echo -e "${YELLOW}Konfigurasi di /etc/captive tetap disimpan.${NC}"
fi

echo -e "\n${GREEN}Uninstalasi selesai.${NC}"
