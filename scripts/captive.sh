#!/bin/bash
# ==============================================================================
# Script Auto-Login Captive Portal PENS dengan Rotasi Akun & Dukungan Logout
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

# Nilai default untuk file state dan flags jika belum ada di config.env
SESSION_FILE="${SESSION_FILE:-/var/local/captive_session.txt}"
COOKIE_FILE="${COOKIE_FILE:-/var/local/captive_cookies.txt}"
STATE_FILE="${STATE_FILE:-/var/local/captive_state.txt}"
LOG_FILE="${LOG_FILE:-/var/local/rekap_mingguan.txt}"
NOTIF_STATE="${NOTIF_STATE:-/var/local/last_notified.txt}"
CHECK_URL="${CHECK_URL:-http://www.gstatic.com/generate_204}"

# Ekstraksi otomatis ORIGIN dan ZONE dari LOGIN_URL jika tidak diset manual
if [ -z "$ORIGIN" ]; then
    ORIGIN=$(echo "$LOGIN_URL" | sed -E 's|^(https?://[^/]+).*|\1|')
fi

ZONE=$(echo "$LOGIN_URL" | grep -oP '(?<=zone=)[^&]+' 2>/dev/null || echo "misc")
[ -z "$ZONE" ] && ZONE="misc"

# Validasi Akun
NUM_ACCOUNTS=${#USERS[@]}
NUM_PASSWORDS=${#PASSWORDS[@]}

if [ "$NUM_ACCOUNTS" -eq 0 ] || [ "$NUM_ACCOUNTS" -ne "$NUM_PASSWORDS" ]; then
    echo "[ERROR] Jumlah USERS ($NUM_ACCOUNTS) dan PASSWORDS ($NUM_PASSWORDS) tidak valid atau tidak seimbang!" >&2
    exit 1
fi

# Pastikan folder penyimpanan state & log ada
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true

TODAY=$(date +%Y-%m-%d)

# ------------------------------------------------------------------------------
# Fungsi: Logout dari Captive Portal
# ------------------------------------------------------------------------------
do_logout() {
    echo "[INFO] Menjalankan proses logout dari Captive Portal PENS..."

    # Baca akun aktif
    STATE_DATA=$(cat "$STATE_FILE" 2>/dev/null || echo "2000-01-01:-1")
    CURRENT_INDEX=$(echo "$STATE_DATA" | cut -d':' -f2)
    ACTIVE_USER=""
    if [ -n "$CURRENT_INDEX" ] && [ "$CURRENT_INDEX" -ge 0 ] 2>/dev/null && [ "$CURRENT_INDEX" -lt "$NUM_ACCOUNTS" ]; then
        ACTIVE_USER="${USERS[$CURRENT_INDEX]}"
    fi

    LOGOUT_ID=""
    if [ -f "$SESSION_FILE" ]; then
        LOGOUT_ID=$(grep '^LOGOUT_ID=' "$SESSION_FILE" 2>/dev/null | cut -d'=' -f2-)
    fi

    # 1. Kirim request logout POST dengan logout_id jika ada
    if [ -n "$LOGOUT_ID" ]; then
        curl -k -s --interface "$IFACE" --connect-timeout 5 --max-time 8 -X POST "$LOGIN_URL" \
            -b "$COOKIE_FILE" \
            -H "Content-Type: application/x-www-form-urlencoded" \
            -H "Origin: $ORIGIN" -H "Referer: $LOGIN_URL" \
            -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
            --data "zone=${ZONE}&logout_id=${LOGOUT_ID}&logout=Logout&accept=Logout" >/dev/null 2>&1 || true
    fi

    # 2. Kirim request logout POST umum (pfSense captive portal fallback)
    curl -k -s --interface "$IFACE" --connect-timeout 5 --max-time 8 -X POST "$LOGIN_URL" \
        -b "$COOKIE_FILE" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Origin: $ORIGIN" -H "Referer: $LOGIN_URL" \
        -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
        --data "zone=${ZONE}&logout=Logout&action=Logout" >/dev/null 2>&1 || true

    # 3. Kirim request logout GET fallback
    curl -k -s --interface "$IFACE" --connect-timeout 5 --max-time 8 \
        -b "$COOKIE_FILE" \
        -H "Origin: $ORIGIN" -H "Referer: $LOGIN_URL" \
        -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" \
        "${ORIGIN}/index.php?zone=${ZONE}&logout=1" >/dev/null 2>&1 || true

    # Bersihkan file sesi lama
    rm -f "$SESSION_FILE" "$COOKIE_FILE" "$NOTIF_STATE"

    # Pertahankan akun yang sama agar saat login ulang tetap mencoba akun ini terlebih dahulu
    # (Hanya akan beralih ke akun berikutnya jika akun ini terkena batas limit 3x / gagal)
    if [ -n "$CURRENT_INDEX" ] && [ "$CURRENT_INDEX" -ge 0 ] 2>/dev/null; then
        echo "$TODAY:$CURRENT_INDEX" > "$STATE_FILE"
    fi

    echo "[SUCCESS] Logout berhasil diproses untuk akun: ${ACTIVE_USER:-Tidak diketahui}"
    return 0
}

# ------------------------------------------------------------------------------
# Fungsi: Pengecekan Koneksi Internet (Toleran Jitter & Multi-Endpoint)
# ------------------------------------------------------------------------------
is_online() {
    local test_urls=(
        "$CHECK_URL"
        "http://connectivitycheck.gstatic.com/generate_204"
        "http://cp.cloudflare.com/generate_204"
    )

    # Lakukan 2 kali percobaan.
    # PENTING: HANYA HTTP 204 yang menandakan internet aktif!
    # Jika terkena captive portal, server akan me-redirect dengan HTTP 302 atau memberi HTTP 200 form login.
    for attempt in 1 2; do
        for url in "${test_urls[@]}"; do
            local code
            code=$(curl -s -o /dev/null -w "%{http_code}" --interface "$IFACE" \
                --connect-timeout 4 --max-time 6 "$url" 2>/dev/null || echo "000")
            if [ "$code" = "204" ]; then
                return 0
            fi
        done
        [ "$attempt" -lt 2 ] && sleep 1
    done

    return 1
}

# ------------------------------------------------------------------------------
# Fungsi: Cek apakah portal PENS sudah menganggap perangkat ini login
# ------------------------------------------------------------------------------
is_portal_logged_in() {
    local portal_html
    portal_html=$(curl -k -s --interface "$IFACE" --connect-timeout 5 --max-time 8 "$LOGIN_URL" 2>/dev/null || true)
    # Jika halaman portal menampilkan form login (auth_user), berarti belum login
    if echo "$portal_html" | grep -q "auth_user"; then
        return 1
    fi
    # Jika ada indikasi tombol disconnect / logout_id tanpa form login
    if echo "$portal_html" | grep -qiE '(logout_id|value="Disconnect"|value="Logout"|action="logout")'; then
        return 0
    fi
    return 1
}

# ------------------------------------------------------------------------------
# Fungsi: Status Singkat (CLI)
# ------------------------------------------------------------------------------
do_status() {
    STATE_DATA=$(cat "$STATE_FILE" 2>/dev/null || echo "2000-01-01:-1")
    CURRENT_INDEX=$(echo "$STATE_DATA" | cut -d':' -f2)
    if [ "$CURRENT_INDEX" = "-1" ] || [ -z "$CURRENT_INDEX" ]; then
        USERNAME="Tidak ada (Standby / Sedang Logged Out)"
    elif [ "$CURRENT_INDEX" -lt "$NUM_ACCOUNTS" ] 2>/dev/null; then
        USERNAME="${USERS[$CURRENT_INDEX]}"
    else
        USERNAME="Index tidak valid"
    fi

    if is_online; then
        NET_STATUS="Online (Terhubung)"
    else
        NET_STATUS="Offline / Perlu Login"
    fi

    SERVICE_STATUS=$(systemctl is-active captive.service 2>/dev/null || echo "unknown")

    echo "=== AutoLogin Captive Status ==="
    echo "Interface         : $IFACE"
    echo "Portal Login URL  : $LOGIN_URL"
    echo "Akun Aktif        : $USERNAME"
    echo "Status Internet   : $NET_STATUS"
    echo "Service captive   : $SERVICE_STATUS"
}

# ------------------------------------------------------------------------------
# Pengolahan Argumen Command Line
# ------------------------------------------------------------------------------
case "$1" in
    --logout|logout)
        do_logout
        exit 0
        ;;
    --status|status)
        do_status
        exit 0
        ;;
esac

# ------------------------------------------------------------------------------
# 2. State Management (Memori akun aktif terakhir)
# ------------------------------------------------------------------------------
if [ ! -f "$STATE_FILE" ]; then
    echo "2000-01-01:-1" > "$STATE_FILE"
fi

STATE_DATA=$(cat "$STATE_FILE")
LAST_DATE=$(echo "$STATE_DATA" | cut -d':' -f1)
CURRENT_INDEX=$(echo "$STATE_DATA" | cut -d':' -f2)

if ! [[ "$CURRENT_INDEX" =~ ^-?[0-9]+$ ]] || [ "$CURRENT_INDEX" -ge "$NUM_ACCOUNTS" ]; then
    CURRENT_INDEX=-1
fi

# ------------------------------------------------------------------------------
# 3. Pengecekan Jaringan
# ------------------------------------------------------------------------------
# Cek apakah interface dalam kondisi UP
if ! ip link show "$IFACE" 2>/dev/null | grep -q "state UP"; then
    exit 0
fi

# Cek apakah internet sudah tersambung (multi-endpoint + retry)
if is_online; then
    # Internet sudah aktif dan stabil, tidak perlu login
    exit 0
fi

# Jika internet offline tapi portal masih mendeteksi sesi lama (zombie session),
# lakukan logout bersih terlebih dahulu agar sesi tidak bentrok/tabrakan di pfSense
if is_portal_logged_in; then
    echo "[WARN] Terdeteksi sesi portal lama yang menggantung (stale / zombie). Melakukan logout bersih terlebih dahulu..."
    do_logout >/dev/null 2>&1 || true
    sleep 2
fi

# ------------------------------------------------------------------------------
# 4. Logika Rotasi Akun & Login
# ------------------------------------------------------------------------------
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
    RESPONSE=$(curl -k -s --interface "$IFACE" --connect-timeout 8 --max-time 12 -X POST "$LOGIN_URL" \
        -c "$COOKIE_FILE" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -H "Origin: $ORIGIN" -H "Referer: $LOGIN_URL" \
        -A "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36" --data "$DATA" 2>/dev/null)

    # Deteksi jika limit 3 login tercapai atau login gagal
    if echo "$RESPONSE" | grep -q "You are already logged in 3 times" || echo "$RESPONSE" | grep -iq "login failed"; then
        CURRENT_INDEX=$(( (CURRENT_INDEX + 1) % NUM_ACCOUNTS ))
        ATTEMPTS=$((ATTEMPTS + 1))
        sleep 1
        continue
    fi

    # Verifikasi apakah internet benar-benar terhubung setelah request login
    sleep 2
    if is_online; then
        # 1. Simpan State Akun Aktif
        echo "$TODAY:$CURRENT_INDEX" > "$STATE_FILE"

        # 2. Ekstrak logout_id / session id jika tersedia pada halaman respon
        LOGOUT_ID=$(echo "$RESPONSE" | grep -oP '(?<=name="logout_id" value=")[^"]+' | head -n1 2>/dev/null || true)
        if [ -z "$LOGOUT_ID" ]; then
            LOGOUT_ID=$(echo "$RESPONSE" | grep -oP '(?<=logout_id=)[a-zA-Z0-9_-]+' | head -n1 2>/dev/null || true)
        fi

        LOGOUT_URL="${ORIGIN}/index.php?zone=${ZONE}&logout=1"
        if [ -n "$LOGOUT_ID" ]; then
            LOGOUT_URL="${ORIGIN}/index.php?zone=${ZONE}&logout_id=${LOGOUT_ID}&logout=Logout"
        fi

        cat <<EOF > "$SESSION_FILE"
LOGIN_TIME=$(date '+%Y-%m-%d %H:%M:%S')
USERNAME=$USERNAME
LOGIN_URL=$LOGIN_URL
ORIGIN=$ORIGIN
ZONE=$ZONE
LOGOUT_ID=$LOGOUT_ID
LOGOUT_URL=$LOGOUT_URL
EOF

        # 3. Catat Riwayat Login
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

        # 4. Notifikasi Telegram (Hanya dikirim jika belum ada notifikasi untuk hari & akun ini)
        LAST_NOTIF=$(cat "$NOTIF_STATE" 2>/dev/null || echo "")
        if [ "$LAST_NOTIF" != "$TODAY:$CURRENT_INDEX" ] && [ -n "$BOT_TOKEN" ] && [ "$BOT_TOKEN" != "YOUR_BOT_TOKEN_HERE" ]; then
            DATE_STR=$(LC_ALL=id_ID.UTF-8 date '+%d %B %Y' 2>/dev/null || date '+%d %b %Y')
            TIME_STR=$(date '+%H:%M')

            MSG="✅ <b>Autologin PENS Aktif</b>
📅 Tanggal: $DATE_STR
⏰ Jam: $TIME_STR
👤 Akun: <code>$USERNAME</code>
🌐 Portal: <code>$LOGIN_URL</code>

📊 <b>Riwayat Rotasi Terakhir:</b>
---------------------------------------
"
            if [ -f "$LOG_FILE" ]; then
                while IFS= read -r line; do
                    MSG+="$line"$'\n'
                done < "$LOG_FILE"
            fi

            MSG+=$'\n'
            MSG+="💡 <i>Gunakan tombol menu di bawah untuk aksi cepat:</i>"

            KEYBOARD_JSON='{"inline_keyboard":[[{"text":"📊 Status Captive","callback_data":"/status"},{"text":"📜 Riwayat Login","callback_data":"/riwayat"}],[{"text":"🚪 Logout & Login Ulang","callback_data":"/logout"},{"text":"🌐 URL Portal","callback_data":"/url"}],[{"text":"⚙️ Status Service","callback_data":"/service"},{"text":"🖥 Info VM & Server","callback_data":"/vm"}]]}'

            curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
                -d "chat_id=${CHAT_ID}" \
                --data-urlencode "text=${MSG}" \
                -d "parse_mode=HTML" \
                --data-urlencode "reply_markup=${KEYBOARD_JSON}" > /dev/null 2>&1 || true

            echo "$TODAY:$CURRENT_INDEX" > "$NOTIF_STATE"
        fi

        SUCCESS=1
        echo "[SUCCESS] Berhasil terhubung ke internet dengan akun: $USERNAME"
        break
    else
        echo "[WARN] POST login terkirim untuk $USERNAME tapi internet belum terhubung. Mencoba akun berikutnya..."
        CURRENT_INDEX=$(( (CURRENT_INDEX + 1) % NUM_ACCOUNTS ))
        ATTEMPTS=$((ATTEMPTS + 1))
        sleep 1
    fi
done

exit 0
