#!/bin/bash
# ==============================================================================
# Telegram Bot Listener untuk AutoLogin Captive PENS & Monitoring VM / Service
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

# Pastikan dependensi terpasang
if ! command -v jq &> /dev/null; then
    echo "[ERROR] 'jq' belum terpasang. Jalankan: sudo apt install jq" >&2
    exit 1
fi

# Defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CAPTIVE_BIN="/usr/local/bin/captive.sh"
if [ ! -f "$CAPTIVE_BIN" ]; then
    CAPTIVE_BIN="$SCRIPT_DIR/captive.sh"
fi

SESSION_FILE="${SESSION_FILE:-/var/local/captive_session.txt}"
COOKIE_FILE="${COOKIE_FILE:-/var/local/captive_cookies.txt}"
STATE_FILE="${STATE_FILE:-/var/local/captive_state.txt}"
LOG_FILE="${LOG_FILE:-/var/local/rekap_mingguan.txt}"
CHECK_URL="${CHECK_URL:-http://www.gstatic.com/generate_204}"
CHECK_INTERVAL="${CHECK_INTERVAL:-30}"
NOTIFY_VM_ON_START="${NOTIFY_VM_ON_START:-true}"

if [ -z "$ORIGIN" ]; then
    ORIGIN=$(echo "$LOGIN_URL" | sed -E 's|^(https?://[^/]+).*|\1|')
fi
ZONE=$(echo "$LOGIN_URL" | grep -oP '(?<=zone=)[^&]+' 2>/dev/null || echo "misc")
[ -z "$ZONE" ] && ZONE="misc"

NUM_ACCOUNTS=${#USERS[@]}

# ------------------------------------------------------------------------------
# Tombol Menu Interaktif Telegram (Inline Keyboard)
# ------------------------------------------------------------------------------
INLINE_KEYBOARD_JSON='{"inline_keyboard":[[{"text":"📊 Status Captive","callback_data":"/status"},{"text":"📜 Riwayat Login","callback_data":"/riwayat"}],[{"text":"🚪 Logout & Login Ulang","callback_data":"/logout"},{"text":"🌐 URL Portal","callback_data":"/url"}],[{"text":"⚙️ Status Service","callback_data":"/service"},{"text":"🖥 Info VM & Server","callback_data":"/vm"}]]}'

# ------------------------------------------------------------------------------
# Fungsi Kirim Pesan Telegram (dengan Inline Keyboard)
# ------------------------------------------------------------------------------
send_telegram() {
    local text="$1"
    local chat="${2:-$CHAT_ID}"
    curl -s --max-time 10 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d "chat_id=${chat}" \
        --data-urlencode "text=${text}" \
        -d "parse_mode=HTML" \
        --data-urlencode "reply_markup=${INLINE_KEYBOARD_JSON}" > /dev/null 2>&1
}

# ------------------------------------------------------------------------------
# Fungsi Baca Riwayat Rotasi Akun
# ------------------------------------------------------------------------------
get_history_text() {
    if [ -f "$LOG_FILE" ] && [ -s "$LOG_FILE" ]; then
        local history_lines=""
        while IFS= read -r line; do
            [ -n "$line" ] && history_lines+="$line"$'\n'
        done < "$LOG_FILE"
        echo "$history_lines"
    else
        echo "<i>(Belum ada riwayat tercatat)</i>"$'\n'
    fi
}


# ------------------------------------------------------------------------------
# Fungsi Status Service Systemd (Captive & Bot)
# ------------------------------------------------------------------------------
get_service_status_text() {
    local service_name="$1"
    local is_installed
    local is_act
    local main_pid
    local since_time

    # Cek apakah unit file ada di systemd
    if ! systemctl list-unit-files "$service_name" 2>/dev/null | grep -q "$service_name"; then
        echo "⚪ <b>Belum Terpasang</b> (Jalankan <code>sudo ./install.sh</code>)"
        return
    fi

    is_act=$(systemctl is-active "$service_name" 2>/dev/null || echo "inactive")
    main_pid=$(systemctl show "$service_name" --property=MainPID 2>/dev/null | cut -d'=' -f2)
    since_time=$(systemctl show "$service_name" --property=ActiveEnterTimestamp 2>/dev/null | cut -d'=' -f2)

    case "$is_act" in
        active)
            if [ -n "$since_time" ] && [ "$since_time" != "N/A" ]; then
                echo "🟢 <b>HIDUP (Running)</b> [PID: ${main_pid:-?}]"$'\n'"   ⏱ Sejak: <i>$since_time</i>"
            else
                echo "🟢 <b>HIDUP (Running)</b> [PID: ${main_pid:-?}]"
            fi
            ;;
        failed)
            echo "🔴 <b>ERROR / GAGAL (Failed)</b>"$'\n'"   ⚠️ Perlu dicek: <code>sudo systemctl restart $service_name</code>"
            ;;
        inactive|deactivating)
            echo "🔴 <b>MATI (Stopped / Inactive)</b>"$'\n'"   💡 Untuk mengaktifkan: <code>sudo systemctl start $service_name</code>"
            ;;
        *)
            echo "🟡 <b>$is_act</b>"
            ;;
    esac
}

# ------------------------------------------------------------------------------
# Fungsi Menu /service (Detail Status Service)
# ------------------------------------------------------------------------------
get_service_report() {
    local cap_status
    local bot_status
    local net_code
    local net_status
    local active_user
    local current_index

    cap_status=$(get_service_status_text "captive.service")
    bot_status=$(get_service_status_text "captive-bot.service")

    net_code=$(curl -s -o /dev/null -w "%{http_code}" --interface "$IFACE" --connect-timeout 4 --max-time 5 "$CHECK_URL" 2>/dev/null || echo "000")
    if [ "$net_code" = "204" ]; then
        net_status="🟢 Online (Terhubung)"
    else
        net_status="🔴 Offline / Perlu Login (HTTP $net_code)"
    fi

    current_index=$(cut -d':' -f2 "$STATE_FILE" 2>/dev/null || echo "-1")
    if [ "$current_index" = "-1" ] || [ -z "$current_index" ]; then
        active_user="Standby / Belum Ada Akun Aktif"
    elif [ "$current_index" -lt "$NUM_ACCOUNTS" ] 2>/dev/null; then
        active_user="${USERS[$current_index]}"
    else
        active_user="Index tidak valid"
    fi

    cat <<EOF
⚙️ <b>Status Service AutoLogin Captive</b>
---------------------------------------
📦 <b>captive.service (Auto-login Loop):</b>
$cap_status

🤖 <b>captive-bot.service (Bot Listener):</b>
$bot_status
---------------------------------------
📶 <b>Status Internet:</b> $net_status
👤 <b>Akun Aktif:</b> <code>$active_user</code>
🔄 <b>Interval Pengecekan:</b> Setiap $CHECK_INTERVAL detik
🔌 <b>Interface:</b> <code>$IFACE</code>
EOF
}

# ------------------------------------------------------------------------------
# Fungsi Pengambilan Status Lengkap VM
# ------------------------------------------------------------------------------
get_vm_info() {
    local host
    local os_name
    local uptime_str
    local cpu_load
    local cpu_cores
    local ram_info
    local disk_info
    local iface_ip
    local cap_active
    local bot_active
    local net_code
    local net_status
    local active_user

    host=$(hostname 2>/dev/null || echo "VM-Linux")
    os_name=$(grep -oP '(?<=PRETTY_NAME=")[^"]+' /etc/os-release 2>/dev/null || uname -s)
    uptime_str=$(uptime -p 2>/dev/null || uptime | awk -F'( |,|:)+' '{print $6,$7}')
    [ -z "$uptime_str" ] && uptime_str="N/A"

    cpu_cores=$(nproc 2>/dev/null || echo "1")
    cpu_load=$(cat /proc/loadavg 2>/dev/null | awk '{print $1", "$2", "$3}')

    ram_info=$(free -m 2>/dev/null | awk 'NR==2{printf "%s / %s MB (%.1f%%)", $3, $2, $3*100/$2 }')
    [ -z "$ram_info" ] && ram_info="N/A"

    disk_info=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')
    [ -z "$disk_info" ] && disk_info="N/A"

    iface_ip=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1)
    [ -z "$iface_ip" ] && iface_ip="Tidak ada IP"

    cap_active=$(systemctl is-active captive.service 2>/dev/null || echo "inactive")
    bot_active=$(systemctl is-active captive-bot.service 2>/dev/null || echo "active")

    [ "$cap_active" = "active" ] && cap_label="🟢 HIDUP (Running)" || cap_label="🔴 MATI / STOPPED"
    [ "$bot_active" = "active" ] && bot_label="🟢 HIDUP (Running)" || bot_label="🔴 MATI"

    net_code=$(curl -s -o /dev/null -w "%{http_code}" --interface "$IFACE" --connect-timeout 4 --max-time 5 "$CHECK_URL" 2>/dev/null || echo "000")
    if [ "$net_code" = "204" ]; then
        net_status="🟢 Online (HTTP 204)"
    else
        net_status="🔴 Offline (HTTP $net_code)"
    fi

    local current_index
    current_index=$(cut -d':' -f2 "$STATE_FILE" 2>/dev/null || echo "-1")
    if [ "$current_index" = "-1" ] || [ -z "$current_index" ]; then
        active_user="Standby / Belum Login"
    elif [ "$current_index" -lt "$NUM_ACCOUNTS" ] 2>/dev/null; then
        active_user="${USERS[$current_index]}"
    else
        active_user="Index tidak valid ($current_index)"
    fi

    cat <<EOF
🖥 <b>Status Virtual Machine (VM)</b>
---------------------------------------
🏷 <b>Hostname:</b> <code>$host</code>
🐧 <b>OS:</b> $os_name
⏱ <b>Uptime:</b> $uptime_str
⚙️ <b>CPU:</b> $cpu_cores Core | Load: <code>$cpu_load</code>
🧠 <b>RAM:</b> <code>$ram_info</code>
💾 <b>Disk (/):</b> <code>$disk_info</code>
🌐 <b>IP ($IFACE):</b> <code>$iface_ip</code>
---------------------------------------
📦 <b>Status Service:</b>
• captive.service: <b>$cap_label</b>
• captive-bot.service: <b>$bot_label</b>
📶 <b>Status Internet:</b> $net_status
👤 <b>Akun Aktif:</b> <code>$active_user</code>
EOF
}

# ------------------------------------------------------------------------------
# Fungsi Informasi Portal & URL Captive
# ------------------------------------------------------------------------------
get_url_info() {
    local net_code
    local net_status
    local active_user
    local current_index
    local session_time
    local logout_id
    local logout_link
    local detected_redirect

    net_code=$(curl -s -o /dev/null -w "%{http_code}" --interface "$IFACE" --connect-timeout 4 --max-time 5 "$CHECK_URL" 2>/dev/null || echo "000")
    if [ "$net_code" = "204" ]; then
        net_status="🟢 Terhubung (Online)"
    else
        net_status="🔴 Tidak Terhubung / Captive Redirect (HTTP $net_code)"
    fi

    current_index=$(cut -d':' -f2 "$STATE_FILE" 2>/dev/null || echo "-1")
    if [ "$current_index" = "-1" ] || [ -z "$current_index" ]; then
        active_user="Belum ada (Standby)"
    elif [ "$current_index" -lt "$NUM_ACCOUNTS" ] 2>/dev/null; then
        active_user="${USERS[$current_index]}"
    else
        active_user="Tidak diketahui"
    fi

    session_time="N/A"
    logout_id=""
    if [ -f "$SESSION_FILE" ]; then
        session_time=$(grep '^LOGIN_TIME=' "$SESSION_FILE" 2>/dev/null | cut -d'=' -f2-)
        logout_id=$(grep '^LOGOUT_ID=' "$SESSION_FILE" 2>/dev/null | cut -d'=' -f2-)
    fi

    if [ -n "$logout_id" ]; then
        logout_link="${ORIGIN}/index.php?zone=${ZONE}&logout_id=${logout_id}&logout=Logout"
    else
        logout_link="${ORIGIN}/index.php?zone=${ZONE}&logout=1"
    fi

    # Cek apakah ada redirect URL jika akses web luar
    detected_redirect=$(curl -sI --interface "$IFACE" --connect-timeout 3 --max-time 5 "http://neverssl.com" 2>/dev/null | grep -i '^Location:' | tr -d '\r' | awk '{print $2}' | head -n1)

    local msg="🌐 <b>Informasi Portal & URL Captive PENS</b>
---------------------------------------
🔗 <b>URL Login Aktif:</b>
<code>$LOGIN_URL</code>

📍 <b>Host / Origin:</b> <code>$ORIGIN</code>
🏷 <b>Zone:</b> <code>$ZONE</code>
🔌 <b>Interface:</b> <code>$IFACE</code>
📶 <b>Status Internet:</b> $net_status
👤 <b>Akun Login:</b> <code>$active_user</code>"

    if [ -n "$session_time" ] && [ "$session_time" != "N/A" ]; then
        msg+=$'\n'"⏰ <b>Waktu Login:</b> $session_time"
    fi

    if [ -n "$detected_redirect" ]; then
        msg+=$'\n\n'"📡 <b>Redirect Terdeteksi dari Jaringan:</b>"$'\n'
        msg+="<code>$detected_redirect</code>"
    fi

    msg+=$'\n\n'
    msg+="🚪 <b>URL Logout Manual:</b>"$'\n'
    msg+="<code>$logout_link</code>"$'\n\n'
    msg+="💡 <i>Tips: Cukup klik tombol <b>[ 🚪 Logout & Ganti Akun ]</b> di bawah pesan untuk logout otomatis!</i>"

    echo "$msg"
}

# ------------------------------------------------------------------------------
# Kirim Notifikasi Startup VM jika diaktifkan (disertai tombol keyboard)
# ------------------------------------------------------------------------------
if [ "$NOTIFY_VM_ON_START" = "true" ]; then
    HOST_INIT=$(hostname 2>/dev/null || echo "VM")
    OS_INIT=$(grep -oP '(?<=PRETTY_NAME=")[^"]+' /etc/os-release 2>/dev/null || uname -s)
    IP_INIT=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || echo "-")
    UP_INIT=$(uptime -p 2>/dev/null || uptime | awk -F'( |,|:)+' '{print $6,$7}')
    RAM_INIT=$(free -m 2>/dev/null | awk 'NR==2{printf "%s / %s MB (%.1f%%)", $3, $2, $3*100/$2 }')
    DISK_INIT=$(df -h / 2>/dev/null | awk 'NR==2{printf "%s / %s (%s)", $3, $2, $5}')
    CAP_INIT=$(systemctl is-active captive.service 2>/dev/null || echo "inactive")
    [ "$CAP_INIT" = "active" ] && CAP_LABEL="🟢 HIDUP" || CAP_LABEL="🔴 MATI"

    STARTUP_MSG="🚀 <b>VM AutoLogin Captive Telah Online!</b>

🖥 <b>Hostname:</b> <code>$HOST_INIT</code> ($OS_INIT)
🌐 <b>IP ($IFACE):</b> <code>$IP_INIT</code>
⏱ <b>Uptime:</b> $UP_INIT
🧠 <b>RAM:</b> <code>$RAM_INIT</code>
💾 <b>Disk (/):</b> <code>$DISK_INIT</code>
⚙️ <b>Service Captive:</b> $CAP_LABEL

👇 <b>Gunakan tombol di bawah untuk berinteraksi:</b>"

    send_telegram "$STARTUP_MSG"
fi

OFFSET=0
echo "[INFO] Bot listener aktif untuk Chat ID: $CHAT_ID"

# ------------------------------------------------------------------------------
# Loop Long-polling Telegram API
# ------------------------------------------------------------------------------
while true; do
    RESPONSE=$(curl -s --connect-timeout 20 --max-time 25 "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?offset=${OFFSET}&timeout=15" 2>/dev/null)

    # Pastikan respon valid JSON
    if echo "$RESPONSE" | jq -e '.ok' >/dev/null 2>&1; then
        MAX_UPDATE_ID=$(echo "$RESPONSE" | jq '.result[-1].update_id' 2>/dev/null)
        UPDATE_COUNT=$(echo "$RESPONSE" | jq '.result | length' 2>/dev/null || echo 0)

        if [ "$MAX_UPDATE_ID" != "null" ] && [ -n "$MAX_UPDATE_ID" ] && [ "$UPDATE_COUNT" -gt 0 ]; then
            OFFSET=$((MAX_UPDATE_ID + 1))

            for ((i = 0; i < UPDATE_COUNT; i++)); do
                # Cek apakah update berupa Callback Query (klik tombol Inline) atau Pesan Biasa
                CB_ID=$(echo "$RESPONSE" | jq -r ".result[$i].callback_query.id // empty" 2>/dev/null)

                if [ -n "$CB_ID" ]; then
                    MSG_TEXT=$(echo "$RESPONSE" | jq -r ".result[$i].callback_query.data // empty" 2>/dev/null)
                    SENDER_CHAT_ID=$(echo "$RESPONSE" | jq -r ".result[$i].callback_query.message.chat.id // empty" 2>/dev/null)

                    # Hentikan animasi loading tombol di Telegram
                    curl -s --max-time 5 -X POST "https://api.telegram.org/bot${BOT_TOKEN}/answerCallbackQuery" \
                        -d "callback_query_id=${CB_ID}" >/dev/null 2>&1
                else
                    MSG_TEXT=$(echo "$RESPONSE" | jq -r ".result[$i].message.text // empty" 2>/dev/null)
                    SENDER_CHAT_ID=$(echo "$RESPONSE" | jq -r ".result[$i].message.chat.id // empty" 2>/dev/null)
                fi

                # Abaikan jika chat ID tidak cocok
                if [ "$SENDER_CHAT_ID" != "$CHAT_ID" ]; then
                    continue
                fi

                # Normalisasi perintah (menghapus @BotName jika di grup)
                RAW_CMD=$(echo "$MSG_TEXT" | awk '{print $1}')
                CMD=$(echo "$RAW_CMD" | cut -d'@' -f1 | tr '[:upper:]' '[:lower:]')

                # Tangani baik perintah slash maupun tombol inline
                case "$MSG_TEXT" in
                    /status*|/cek_akun*|*"Status Captive"*|*"Status & Kehadiran"*)
                        STATE_DATA=$(cat "$STATE_FILE" 2>/dev/null || echo "2000-01-01:-1")
                        CURRENT_INDEX=$(echo "$STATE_DATA" | cut -d':' -f2)

                        if [ "$CURRENT_INDEX" = "-1" ] || [ -z "$CURRENT_INDEX" ]; then
                            USERNAME="Belum ada (Standby / Sedang Logged Out)"
                        elif [ "$CURRENT_INDEX" -lt "$NUM_ACCOUNTS" ] 2>/dev/null; then
                            USERNAME="${USERS[$CURRENT_INDEX]}"
                        else
                            USERNAME="Index tidak valid"
                        fi

                        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --interface "$IFACE" --connect-timeout 4 --max-time 5 "$CHECK_URL" 2>/dev/null || echo "000")
                        if [ "$HTTP_CODE" = "204" ]; then
                            NET_STATUS="🟢 Online (Terhubung)"
                        else
                            NET_STATUS="🔴 Offline (HTTP $HTTP_CODE)"
                        fi

                        CAP_IS_ACT=$(systemctl is-active captive.service 2>/dev/null || echo "inactive")
                        if [ "$CAP_IS_ACT" = "active" ]; then
                            SERVICE_BADGE="🟢 <b>HIDUP (Running)</b>"
                        elif [ "$CAP_IS_ACT" = "failed" ]; then
                            SERVICE_BADGE="🔴 <b>ERROR (Failed)</b>"
                        else
                            SERVICE_BADGE="🔴 <b>MATI (Stopped)</b>"
                        fi

                        DATE_STR=$(LC_ALL=id_ID.UTF-8 date '+%d %B %Y' 2>/dev/null || date '+%d %b %Y')
                        TIME_STR=$(date '+%H:%M')
                        UPTIME_SHORT=$(uptime -p 2>/dev/null || uptime | awk -F'( |,|:)+' '{print $6,$7}')
                        RAM_SHORT=$(free -m 2>/dev/null | awk 'NR==2{printf "%.1f%% (%s/%s MB)", $3*100/$2, $3, $2}')
                        IP_SHORT=$(ip -4 addr show "$IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || echo "-")

                        HIST_TEXT=$(get_history_text)

                        REPLY="📊 <b>Status AutoLogin & Service Captive</b>
---------------------------------------
⚙️ <b>Service Captive:</b> $SERVICE_BADGE
📶 <b>Status Internet:</b> $NET_STATUS
👤 <b>Akun Aktif:</b> <code>$USERNAME</code>
🌐 <b>IP ($IFACE):</b> <code>$IP_SHORT</code>
⏱ <b>Uptime VM:</b> $UPTIME_SHORT
🧠 <b>RAM:</b> $RAM_SHORT
📅 <b>Waktu:</b> $DATE_STR ($TIME_STR)

📊 <b>Riwayat Rotasi Terakhir:</b>
---------------------------------------
${HIST_TEXT}---------------------------------------
👇 <i>Gunakan tombol menu di bawah untuk aksi cepat:</i>"

                        send_telegram "$REPLY" "$SENDER_CHAT_ID"
                        ;;

                    /riwayat*|/rekap*|/history*|/log*|*"Riwayat"*)
                        DATE_STR=$(LC_ALL=id_ID.UTF-8 date '+%d %B %Y' 2>/dev/null || date '+%d %b %Y')
                        TIME_STR=$(date '+%H:%M')

                        STATE_DATA=$(cat "$STATE_FILE" 2>/dev/null || echo "2000-01-01:-1")
                        CURRENT_INDEX=$(echo "$STATE_DATA" | cut -d':' -f2)
                        if [ "$CURRENT_INDEX" = "-1" ] || [ -z "$CURRENT_INDEX" ]; then
                            USERNAME="Belum ada (Standby)"
                        elif [ "$CURRENT_INDEX" -lt "$NUM_ACCOUNTS" ] 2>/dev/null; then
                            USERNAME="${USERS[$CURRENT_INDEX]}"
                        else
                            USERNAME="Index tidak valid"
                        fi

                        HIST_TEXT=$(get_history_text)

                        REPLY="📜 <b>Riwayat Rotasi Akun Mahasiswa PENS</b>
---------------------------------------
📅 <b>Tanggal:</b> $DATE_STR
⏰ <b>Jam:</b> $TIME_STR
👤 <b>Akun Aktif:</b> <code>$USERNAME</code>

📊 <b>Riwayat Rotasi Terakhir:</b>
---------------------------------------
${HIST_TEXT}---------------------------------------
💡 <i>Histori di atas mencatat akun-akun yang berhasil login dan waktu aktivasinya.</i>"

                        send_telegram "$REPLY" "$SENDER_CHAT_ID"
                        ;;

                    /service*|/service_status*|/cek_service*|*"Status Service"*)
                        SRV_MSG=$(get_service_report)
                        send_telegram "$SRV_MSG" "$SENDER_CHAT_ID"
                        ;;

                    /url*|/portal*|/login_url*|*"URL Portal"*)
                        URL_MSG=$(get_url_info)
                        send_telegram "$URL_MSG" "$SENDER_CHAT_ID"
                        ;;

                    /logout*|*"Logout"*)
                        STATE_DATA=$(cat "$STATE_FILE" 2>/dev/null || echo "2000-01-01:-1")
                        CURRENT_INDEX=$(echo "$STATE_DATA" | cut -d':' -f2)

                        OLD_USER=""
                        if [ "$CURRENT_INDEX" != "-1" ] && [ -n "$CURRENT_INDEX" ] && [ "$CURRENT_INDEX" -lt "$NUM_ACCOUNTS" ] 2>/dev/null; then
                            OLD_USER="${USERS[$CURRENT_INDEX]}"
                        fi

                        send_telegram "⏳ Sedang memproses logout dan menghubungkan ulang..." "$SENDER_CHAT_ID"

                        # 1. Jalankan logout sesi portal (tetap pertahankan index akun saat ini)
                        "$CAPTIVE_BIN" --logout >/dev/null 2>&1

                        # 2. Langsung login ulang (mencoba akun yang sama dulu, fallback jika limit 3x tercapai)
                        "$CAPTIVE_BIN" >/dev/null 2>&1

                        sleep 2
                        HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" --interface "$IFACE" --connect-timeout 4 --max-time 5 "$CHECK_URL" 2>/dev/null || echo "000")

                        # Cek akun aktif setelah login ulang
                        NEW_STATE=$(cat "$STATE_FILE" 2>/dev/null || echo "2000-01-01:-1")
                        NEW_INDEX=$(echo "$NEW_STATE" | cut -d':' -f2)
                        ACTIVE_USER=""
                        if [ "$NEW_INDEX" != "-1" ] && [ -n "$NEW_INDEX" ] && [ "$NEW_INDEX" -lt "$NUM_ACCOUNTS" ] 2>/dev/null; then
                            ACTIVE_USER="${USERS[$NEW_INDEX]}"
                        fi

                        LOGOUT_RESP="🚪 <b>Logout & Login Ulang Selesai!</b>
---------------------------------------"
                        if [ "$ACTIVE_USER" = "$OLD_USER" ] && [ -n "$ACTIVE_USER" ]; then
                            LOGOUT_RESP+=$'\n'"👤 <b>Akun Aktif:</b> <code>$ACTIVE_USER</code> (Akun tetap sama & masih valid)"
                        else
                            if [ -n "$OLD_USER" ]; then
                                LOGOUT_RESP+=$'\n'"👤 <b>Akun Sebelumnya:</b> <code>$OLD_USER</code> (Batas limit tercapai / gagal)"
                            fi
                            if [ -n "$ACTIVE_USER" ]; then
                                LOGOUT_RESP+=$'\n'"🔄 <b>Akun Baru (Fallback):</b> <code>$ACTIVE_USER</code>"
                            fi
                        fi

                        if [ "$HTTP_CODE" = "204" ]; then
                            LOGOUT_RESP+=$'\n'"📶 <b>Status Internet:</b> 🟢 Terhubung (HTTP 204)"
                        else
                            LOGOUT_RESP+=$'\n'"📶 <b>Status Internet:</b> 🟡 Sedang proses (HTTP $HTTP_CODE)"$'\n'"<i>Service captive di background akan terus mencoba menghubungkan setiap $CHECK_INTERVAL detik.</i>"
                        fi

                        LOGOUT_RESP+=$'\n'"🌐 <b>Portal:</b> <code>$LOGIN_URL</code>"

                        send_telegram "$LOGOUT_RESP" "$SENDER_CHAT_ID"
                        ;;

                    /vm*|/vmstatus*|/server*|*"Info VM & Server"*|*"Info VM"*)
                        VM_MSG=$(get_vm_info)
                        send_telegram "$VM_MSG" "$SENDER_CHAT_ID"
                        ;;

                    /help*|/bantuan*|/start*|*"Bantuan"*)
                        HELP_TEXT="🤖 <b>Bantuan Bot Captive PENS & VM Monitor</b>

Silakan langsung klik tombol menu di bawah ini:
👉 <b>📊 Status Captive</b> : Cek akun aktif, koneksi internet, riwayat rotasi, & status service
👉 <b>📜 Riwayat Login</b> : Lihat daftar lengkap akun yang pernah login & histori rotasi
👉 <b>🚪 Logout & Login Ulang</b> : Logout sesi portal & login ulang (tetap gunakan akun ini jika masih valid)
👉 <b>🌐 URL Portal</b> : Minta URL captive portal & link logout saat ini
👉 <b>⚙️ Status Service</b> : Cek apakah service captive sedang HIDUP atau MATI
👉 <b>🖥 Info VM & Server</b> : Cek performa & kondisi lengkap VM (CPU, RAM, Disk, Uptime, IP)

👇 <i>Pilih salah satu tombol di bawah untuk menjalankan perintah:</i>"

                        send_telegram "$HELP_TEXT" "$SENDER_CHAT_ID"
                        ;;
                esac
            done
        fi
    fi

    sleep 1
done
