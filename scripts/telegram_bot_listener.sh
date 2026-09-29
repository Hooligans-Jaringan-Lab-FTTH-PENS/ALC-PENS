#!/bin/bash
# ==============================================================================
# Telegram Bot Listener untuk AutoLogin Captive PENS
# ==============================================================================

# 1. Muat Konfigurasi
CONFIG_FILE="${CAPTIVE_CONFIG:-/etc/captive/config.env}"

if [ ! -f "$CONFIG_FILE" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "$SCRIPT_DIR/../config.env" ]; then
        CONFIG_FILE="$SCRIPT_DIR/../config.env"
    elif [ -f "$SCRIPT_DIR/config.env" ]; then
        CONFIG_FILE="$SCRIPT_DIR/config.env"
    else
        echo "[ERROR] File konfigurasi tidak ditemukan di $CONFIG_FILE!" >&2
        exit 1
    fi
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Validasi Bot Token
if [ -z "$BOT_TOKEN" ] || [ "$BOT_TOKEN" = "YOUR_BOT_TOKEN_HERE" ]; then
    echo "[ERROR] BOT_TOKEN belum dikonfigurasi di $CONFIG_FILE!" >&2
    exit 1
fi

# Pastikan jq terinstall
if ! command -v jq &> /dev/null; then
    echo "[ERROR] 'jq' belum terpasang. Jalankan: sudo apt install jq" >&2
    exit 1
fi

OFFSET=0
echo "[INFO] Bot listener aktif untuk Chat ID: $CHAT_ID"

# Loop long-polling Telegram API
while true; do
    RESPONSE=$(curl -s --connect-timeout 20 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=${OFFSET}&timeout=15" 2>/dev/null)
    
    # Ekstrak data menggunakan jq
    UPDATE_ID=$(echo "$RESPONSE" | jq '.result[-1].update_id' 2>/dev/null)
    MSG_TEXT=$(echo "$RESPONSE" | jq -r '.result[-1].message.text' 2>/dev/null)
    SENDER_CHAT_ID=$(echo "$RESPONSE" | jq -r '.result[-1].message.chat.id' 2>/dev/null)

    # Proses pesan jika ada update baru
    if [ "$UPDATE_ID" != "null" ] && [ -n "$UPDATE_ID" ]; then
        OFFSET=$((UPDATE_ID + 1)) # Tandai pesan sudah terbaca

        # Verifikasi pengirim (hanya tanggapi jika dari chat/grup yang ditentukan)
        if [ "$SENDER_CHAT_ID" == "$CHAT_ID" ]; then
            
            case "$MSG_TEXT" in
                /cek_akun*|/status*)
                    STATE_DATA=$(cat "$STATE_FILE" 2>/dev/null || echo "2000-01-01:-1")
                    CURRENT_INDEX=$(echo "$STATE_DATA" | cut -d':' -f2)

                    if [ "$CURRENT_INDEX" == "-1" ] || [ -z "$CURRENT_INDEX" ]; then
                        USERNAME="Belum ada (Sistem masih standby)"
                    else
                        USERNAME="${USERS[$CURRENT_INDEX]}"
                    fi

                    REPLY="✅ <b>Autologin PENS Aktif</b>%0A📅 Tanggal: $(LC_ALL=id_ID.UTF-8 date '+%d %B %Y' 2>/dev/null || date '+%d %b %Y')%0A⏰ Jam: $(date '+%H:%M')%0A👤 Akun Aktif: <code>$USERNAME</code>"

                    # Kirim balasan
                    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                        -d "chat_id=${CHAT_ID}" \
                        -d "text=${REPLY}" \
                        -d "parse_mode=HTML" > /dev/null 2>&1
                    ;;

                /help*|/bantuan*)
                    HELP_TEXT="🤖 <b>Bantuan Bot Captive PENS</b>%0A%0A"
                    HELP_TEXT+="Perintah yang tersedia:%0A"
                    HELP_TEXT+="👉 <code>/cek_akun</code> atau <code>/status</code> : Cek akun mahasiswa yang sedang login aktif%0A"
                    HELP_TEXT+="👉 <code>/help</code> : Tampilkan menu bantuan ini"

                    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                        -d "chat_id=${CHAT_ID}" \
                        -d "text=${HELP_TEXT}" \
                        -d "parse_mode=HTML" > /dev/null 2>&1
                    ;;
            esac
        fi
    fi

    sleep 1
done
