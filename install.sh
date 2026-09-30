#!/bin/bash
# ==============================================================================
# Script Instalasi Otomatis AutoLogin Captive PENS
# ==============================================================================

set -e

# Warna untuk output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}====================================================${NC}"
echo -e "${BLUE}     Instalasi AutoLogin Captive Portal PENS        ${NC}"
echo -e "${BLUE}====================================================${NC}"

# 1. Pastikan dijalankan sebagai root / sudo
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}[ERROR] Harap jalankan script ini dengan sudo:${NC}"
    echo "  sudo ./install.sh"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 2. Cek dan install dependensi
echo -e "\n${YELLOW}[1/5] Memeriksa dependensi (curl, jq)...${NC}"
MISSING_PKGS=()
for pkg in curl jq; do
    if ! command -v "$pkg" &> /dev/null; then
        MISSING_PKGS+=("$pkg")
    fi
done

if [ ${#MISSING_PKGS[@]} -gt 0 ]; then
    echo -e "${YELLOW}Menginstall paket yang belum terpasang: ${MISSING_PKGS[*]}...${NC}"
    if command -v apt-get &> /dev/null; then
        apt-get update -qq && apt-get install -y "${MISSING_PKGS[@]}"
    elif command -v dnf &> /dev/null; then
        dnf install -y "${MISSING_PKGS[@]}"
    elif command -v pacman &> /dev/null; then
        pacman -Sy --noconfirm "${MISSING_PKGS[@]}"
    else
        echo -e "${RED}[WARNING] Paket manager tidak dikenali. Harap install manual: ${MISSING_PKGS[*]}${NC}"
    fi
else
    echo -e "${GREEN}✓ Semua dependensi sudah terpasang.${NC}"
fi

# 3. Setup direktori konfigurasi & izin akses
echo -e "\n${YELLOW}[2/5] Menyiapkan konfigurasi di /etc/captive/...${NC}"
mkdir -p /etc/captive
mkdir -p /var/local

if [ ! -f /etc/captive/config.env ]; then
    if [ -f "$SCRIPT_DIR/config.env" ]; then
        cp "$SCRIPT_DIR/config.env" /etc/captive/config.env
        echo -e "${GREEN}✓ Menggunakan file 'config.env' yang sudah ada di folder ini.${NC}"
    else
        cp "$SCRIPT_DIR/config.env.example" /etc/captive/config.env
        echo -e "${YELLOW}✓ Dibuat konfigurasi baru di /etc/captive/config.env dari template.${NC}"
        echo -e "${YELLOW}! PENTING: Jangan lupa sesuaikan akun & password di /etc/captive/config.env${NC}"
    fi
else
    if [ -f "$SCRIPT_DIR/config.env" ]; then
        cp /etc/captive/config.env /etc/captive/config.env.bak 2>/dev/null || true
        cp "$SCRIPT_DIR/config.env" /etc/captive/config.env
        echo -e "${GREEN}✓ Memperbarui /etc/captive/config.env dari folder proyek (backup disimpan di config.env.bak).${NC}"
    else
        echo -e "${GREEN}✓ File /etc/captive/config.env sudah ada (tidak ditimpa).${NC}"
    fi
fi

# Amankan izin file konfigurasi agar hanya root yang bisa membaca kredensial
chmod 600 /etc/captive/config.env

# 4. Hentikan service lama jika sedang aktif sebelum replace
echo -e "\n${YELLOW}[3/5] Memeriksa dan membersihkan service/skrip versi lama...${NC}"
if [ -f /etc/systemd/system/tgbot.service ] || systemctl list-unit-files tgbot.service 2>/dev/null | grep -q "tgbot.service"; then
    echo -e "${YELLOW}! Terdeteksi service lama 'tgbot.service'. Menghentikan, mendisable, dan menghapus...${NC}"
    systemctl stop tgbot.service 2>/dev/null || true
    systemctl disable tgbot.service 2>/dev/null || true
    rm -f /etc/systemd/system/tgbot.service
fi

if systemctl is-active --quiet captive.service 2>/dev/null; then
    echo -e "${YELLOW}! Menghentikan captive.service lama sementara selama instalasi...${NC}"
    systemctl stop captive.service 2>/dev/null || true
fi

if systemctl is-active --quiet captive-bot.service 2>/dev/null; then
    systemctl stop captive-bot.service 2>/dev/null || true
fi

# Bersihkan file skrip duplikat lama di /usr/local/bin
rm -f /usr/local/bin/captive_v2.sh /usr/local/bin/captive_v2_baru2.sh

# 5. Salin script eksekusi ke /usr/local/bin
echo -e "\n${YELLOW}[4/5] Memasang skrip ke /usr/local/bin/...${NC}"
cp "$SCRIPT_DIR/scripts/captive.sh" /usr/local/bin/captive.sh
cp "$SCRIPT_DIR/scripts/telegram_bot_listener.sh" /usr/local/bin/telegram_bot_listener.sh

# Beri izin eksekusi
chmod +x /usr/local/bin/captive.sh
chmod +x /usr/local/bin/telegram_bot_listener.sh

# Symlink kompatibilitas jika masih ada sistem lama yang memanggil captive_v2_baru.sh
ln -sf /usr/local/bin/captive.sh /usr/local/bin/captive_v2_baru.sh
echo -e "${GREEN}✓ Skrip berhasil disalin dan diberi izin eksekusi.${NC}"

# 6. Pasang Systemd Services
echo -e "\n${YELLOW}[5/5] Memasang dan memuat ulang Systemd service...${NC}"
cp "$SCRIPT_DIR/systemd/captive.service" /etc/systemd/system/captive.service
cp "$SCRIPT_DIR/systemd/captive-bot.service" /etc/systemd/system/captive-bot.service

systemctl daemon-reload
echo -e "${GREEN}✓ Service unit berhasil dipasang.${NC}"

# 7. Otomatis mulai ulang service jika sudah di-enable
if systemctl is-enabled --quiet captive-bot.service 2>/dev/null || systemctl is-enabled --quiet captive.service 2>/dev/null; then
    echo -e "\n${YELLOW}Memuat ulang dan merestart service...${NC}"
    systemctl restart captive.service captive-bot.service 2>/dev/null || true
    echo -e "${GREEN}✓ Service captive dan bot berhasil dimulai ulang dengan versi terbaru!${NC}"
fi

# 6. Selesai & Panduan
echo -e "\n${GREEN}====================================================${NC}"
echo -e "${GREEN}             INSTALASI BERHASIL!                    ${NC}"
echo -e "${GREEN}====================================================${NC}"
echo -e "\nLangkah selanjutnya:"
echo -e "1. Edit akun mahasiswa & token bot Telegram:"
echo -e "   ${BLUE}sudo nano /etc/captive/config.env${NC}"
echo -e "\n2. Uji coba skrip sekali secara manual:"
echo -e "   ${BLUE}/usr/local/bin/captive.sh${NC}"
echo -e "\n3. Aktifkan service auto-login agar berjalan otomatis setiap 30 detik saat boot:"
echo -e "   ${BLUE}sudo systemctl enable --now captive.service${NC}"
echo -e "\n4. (Opsional) Aktifkan listener bot Telegram:"
echo -e "   ${BLUE}sudo systemctl enable --now captive-bot.service${NC}"
echo -e "\n5. Cek status service kapan saja:"
echo -e "   ${BLUE}sudo systemctl status captive.service${NC}"
echo -e "====================================================\n"
