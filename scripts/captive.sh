#!/bin/bash
# ==============================================================================
# Script Auto-Login Captive Portal PENS dengan Rotasi Akun
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
        echo "[ERROR] File konfigurasi tidak ditemukan di $CONFIG_FILE maupun di folder proyek!" >&2
        exit 1
    fi
fi

# shellcheck source=/dev/null
source "$CONFIG_FILE"

# Validasi Akun
NUM_ACCOUNTS=${#USERS[@]}
NUM_PASSWORDS=${#PASSWORDS[@]}

if [ "$NUM_ACCOUNTS" -eq 0 ] || [ "$NUM_ACCOUNTS" -ne "$NUM_PASSWORDS" ]; then
    echo "[ERROR] Jumlah USERS ($NUM_ACCOUNTS) dan PASSWORDS ($NUM_PASSWORDS) tidak valid atau tidak seimbang!" >&2
    exit 1
fi

# Pastikan folder penyimpanan state & log ada
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true

# 2. State Management (Memori akun aktif terakhir)
TODAY=$(date +%Y-%m-%d)

if [ ! -f "$STATE_FILE" ]; then
    echo "2000-01-01:-1" > "$STATE_FILE"
fi

STATE_DATA=$(cat "$STATE_FILE")
LAST_DATE=$(echo "$STATE_DATA" | cut -d':' -f1)
CURRENT_INDEX=$(echo "$STATE_DATA" | cut -d':' -f2)

if ! [[ "$CURRENT_INDEX" =~ ^-?[0-9]+$ ]] || [ "$CURRENT_INDEX" -ge "$NUM_ACCOUNTS" ]; then
    CURRENT_INDEX=-1
fi

# 3. Pengecekan Jaringan
# Cek apakah interface dalam kondisi UP
if ! ip link show "$IFACE" 2>/dev/null | grep -q "state UP"; then
    exit 0
fi

# Cek apakah internet sudah tersambung (HTTP 204 dari Google gstatic)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --interface "$IFACE" --connect-timeout 5 "$CHECK_URL" 2>/dev/null)
if [ "$HTTP_CODE" = "204" ]; then
    # Internet sudah aktif, tidak perlu login
    exit 0
fi

# 4. Logika Rotasi Akun
# Jika hari berganti, geser ke akun berikutnya
if [ "$TODAY" != "$LAST_DATE" ]; then
    CURRENT_INDEX=$(( (CURRENT_INDEX + 1) % NUM_ACCOUNTS ))
fi

# Jika indeks awal belum terdefinisi (-1), mulai dari 0
if [ "$CURRENT_INDEX" -lt 0 ]; then
    CURRENT_INDEX=0
fi

ATTEMPTS=0
SUCCESS=0

while [ $ATTEMPTS -lt $NUM_ACCOUNTS ]; do
    USERNAME="${USERS[$CURRENT_INDEX]}"
    PASSWORD="${PASSWORDS[$CURRENT_INDEX]}"

    DATA="auth_user=${USERNAME}&auth_pass=${PASSWORD}&redirurl=&accept=Login"
    RESPONSE=$(curl -k -s --interface "$IFACE" --connect-timeout 8 -X POST "$LOGIN_URL" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Origin: $ORIGIN" -H "Referer: $LOGIN_URL" \
        -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" --data "$DATA" 2>/dev/null)

    # Deteksi jika limit 3 login tercapai atau login gagal
    if echo "$RESPONSE" | grep -q "You are already logged in 3 times" || echo "$RESPONSE" | grep -iq "login failed"; then
        CURRENT_INDEX=$(( (CURRENT_INDEX + 1) % NUM_ACCOUNTS ))
        ATTEMPTS=$((ATTEMPTS + 1))
    else
        # 1. Simpan State Akun Aktif
        echo "$TODAY:$CURRENT_INDEX" > "$STATE_FILE"

        # 2. Catat Riwayat Login
        DAY_KEY=$(LC_ALL=id_ID.UTF-8 date '+%A, %d %b' 2>/dev/null || date '+%a, %d %b')
        LOG_TIME=$(date '+%H:%M')

        if [ -f "$LOG_FILE" ]; then
            grep -v "^$DAY_KEY" "$LOG_FILE" > "$LOG_FILE.tmp" 2>/dev/null || true
        else
            > "$LOG_FILE.tmp"
        fi

        echo "$DAY_KEY | $LOG_TIME | $USERNAME" >> "$LOG_FILE.tmp"
        tail -n 7 "$LOG_FILE.tmp" > "$LOG_FILE" 2>/dev/null || true
        rm -f "$LOG_FILE.tmp"

        # 3. Notifikasi Telegram (Hanya dikirim jika belum ada notifikasi untuk hari & akun ini)
        LAST_NOTIF=$(cat "$NOTIF_STATE" 2>/dev/null || echo "")
        if [ "$LAST_NOTIF" != "$TODAY:$CURRENT_INDEX" ] && [ -n "$BOT_TOKEN" ] && [ "$BOT_TOKEN" != "YOUR_BOT_TOKEN_HERE" ]; then
            MSG="✅ <b>Autologin PENS Aktif</b>%0A📅 Tanggal: $(LC_ALL=id_ID.UTF-8 date '+%d %B %Y' 2>/dev/null || date '+%d %b %Y')%0A⏰ Jam: $(date '+%H:%M')%0A👤 Akun: <code>$USERNAME</code>%0A%0A📊 <b>Riwayat Rotasi Terakhir:</b>%0A---------------------------------------%0A"

            if [ -f "$LOG_FILE" ]; then
                while IFS= read -r line; do
                    ENCODED_LINE=$(echo "$line" | sed 's/ /%20/g' | sed 's/|/%7C/g')
                    MSG+="${ENCODED_LINE}%0A"
                done < "$LOG_FILE"
            fi

            curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                -d "chat_id=${CHAT_ID}" \
                -d "text=${MSG}" \
                -d "parse_mode=HTML" > /dev/null 2>&1 || true

            echo "$TODAY:$CURRENT_INDEX" > "$NOTIF_STATE"
        fi

        SUCCESS=1
        break
    fi
done

exit 0
