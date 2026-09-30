#!/bin/bash
# ==============================================================================
# Skrip Cek Akun Aktif AutoLogin Captive PENS (CLI Cepat)
# ==============================================================================

# Warna output terminal
GREEN='\033[1;32m'
CYAN='\033[1;36m'
YELLOW='\033[1;33m'
RED='\033[1;31m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# 1. Muat Konfigurasi
CONFIG_FILE="${CAPTIVE_CONFIG:-/etc/captive/config.env}"
if [ ! -f "$CONFIG_FILE" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$SCRIPT_DIR/../config.env" ]; then
        CONFIG_FILE="$SCRIPT_DIR/../config.env"
    elif [ -f "$SCRIPT_DIR/config.env" ]; then
        CONFIG_FILE="$SCRIPT_DIR/config.env"
    fi
fi

if [ -f "$CONFIG_FILE" ]; then
    # shellcheck source=/dev/null
    source "$CONFIG_FILE" 2>/dev/null
fi

SESSION_FILE="${SESSION_FILE:-/var/local/captive_session.txt}"
STATE_FILE="${STATE_FILE:-/var/local/captive_state.txt}"
IFACE="${IFACE:-eth0}"
CHECK_URL="${CHECK_URL:-http://www.gstatic.com/generate_204}"

# 2. Ambil Akun Aktif & Waktu Login
ACTIVE_USER=""
LOGIN_TIME=""

if [ -f "$SESSION_FILE" ]; then
    ACTIVE_USER=$(grep '^USERNAME=' "$SESSION_FILE" 2>/dev/null | cut -d'=' -f2-)
    LOGIN_TIME=$(grep '^LOGIN_TIME=' "$SESSION_FILE" 2>/dev/null | cut -d'=' -f2-)
fi

# Fallback ke STATE_FILE jika SESSION_FILE belum ada / kosong
if [ -z "$ACTIVE_USER" ] && [ -f "$STATE_FILE" ]; then
    STATE_DATA=$(cat "$STATE_FILE" 2>/dev/null)
    INDEX=$(echo "$STATE_DATA" | cut -d':' -f2)
    if [ -n "$INDEX" ] && [ "$INDEX" -ge 0 ] 2>/dev/null && [ "$INDEX" -lt "${#USERS[@]}" ]; then
        ACTIVE_USER="${USERS[$INDEX]}"
    fi
fi

[ -z "$ACTIVE_USER" ] && ACTIVE_USER="Belum ada akun yang login (Standby / Offline)"
[ -z "$LOGIN_TIME" ] && LOGIN_TIME="Tidak tercatat"

# 3. Cek Status Koneksi Internet
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --interface "$IFACE" --connect-timeout 3 --max-time 4 "$CHECK_URL" 2>/dev/null || echo "000")
if [ "$HTTP_CODE" = "204" ]; then
    NET_STATUS="${GREEN}Online (Terhubung ke Internet)${NC}"
else
    NET_STATUS="${RED}Offline / Perlu Login (HTTP $HTTP_CODE)${NC}"
fi

# 4. Cek Status Service
SVC_ACTIVE=$(systemctl is-active captive.service 2>/dev/null)
[ -z "$SVC_ACTIVE" ] && SVC_ACTIVE="unknown"

if [ "$SVC_ACTIVE" = "active" ]; then
    SVC_STATUS="${GREEN}Active (Running)${NC}"
elif [ "$SVC_ACTIVE" = "failed" ]; then
    SVC_STATUS="${RED}Failed / Error${NC}"
else
    SVC_STATUS="${YELLOW}$SVC_ACTIVE${NC}"
fi

# 5. Ambil IP Interface
IFACE_IP=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || echo "-")

# 6. Tampilkan Hasil ke Terminal
echo -e "${CYAN}====================================================${NC}"
echo -e "${BOLD}         STATUS AKUN AUTO-LOGIN CAPTIVE PENS        ${NC}"
echo -e "${CYAN}====================================================${NC}"
echo -e " 👤 ${BOLD}Akun Aktif     :${NC} ${GREEN}${ACTIVE_USER}${NC}"
echo -e " ⏰ ${BOLD}Waktu Login    :${NC} ${LOGIN_TIME}"
echo -e " 📶 ${BOLD}Status Internet:${NC} ${NET_STATUS}"
echo -e " 🌐 ${BOLD}IP ($IFACE)     :${NC} ${IFACE_IP}"
echo -e " ⚙️  ${BOLD}Service Bot    :${NC} ${SVC_STATUS}"
echo -e "${CYAN}====================================================${NC}"
