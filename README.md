# AutoLogin Captive PENS

Skrip auto-login captive portal PENS (`iac7.pens.ac.id:8009`) untuk Linux. Dilengkapi fitur rotasi multi-akun harian, failover otomatis saat akun terkena batas limit (*logged in 3 times*), dan bot listener Telegram untuk monitoring.

Dibuat untuk kebutuhan PC Lab, server riset, atau mini PC (seperti Raspberry Pi) yang butuh koneksi internet kampus tetap aktif 24/7 tanpa harus buka browser untuk login ulang manual.

---

### Cara Kerja
1. Pengecekan status internet dilakukan berkala (default setiap 30 detik) via request ke `http://www.gstatic.com/generate_204`. Jika respon `204`, skrip langsung keluar tanpa membebani sistem.
2. Jika koneksi terputus, skrip mengirim POST login ke captive portal PENS menggunakan akun yang dijadwalkan hari itu.
3. Jika akun tersebut gagal atau muncul notifikasi *"You are already logged in 3 times"*, skrip otomatis beralih (*fallback*) ke akun cadangan berikutnya di daftar sampai berhasil terhubung.
4. Riwayat akun aktif dicatat dalam rekap mingguan (`/var/local/rekap_mingguan.txt`).
5. Notifikasi perubahan akun dikirim ke grup/chat Telegram, dan tersedia command `/cek_akun` untuk melihat akun yang sedang digunakan.

---

### Struktur File

```text
AutoLoginCaptive/
├── install.sh                  # Skrip installer otomatis
├── uninstall.sh                # Skrip uninstaller
├── config.env.example          # Contoh file konfigurasi (dummy)
├── scripts/
│   ├── captive.sh              # Skrip utama cek internet & auto-login
│   └── telegram_bot_listener.sh# Bot Telegram listener (/cek_akun)
└── systemd/
    ├── captive.service         # Systemd service auto-login (loop 30s)
    └── captive-bot.service     # Systemd service bot Telegram
```

---

### Kebutuhan Sistem
- Linux (Ubuntu, Debian, Raspberry Pi OS, dll)
- Paket dasar: `curl`, `jq`, `iproute2`
- Akses `sudo` / root

---

### Instalasi Cepat

1. Clone repositori:
   ```bash
   git clone https://github.com/USERNAME/AutoLoginCaptive.git
   cd AutoLoginCaptive
   ```

2. Jalankan installer:
   ```bash
   chmod +x install.sh uninstall.sh scripts/*.sh
   sudo ./install.sh
   ```
   Installer akan otomatis mengecek dependensi (`curl`, `jq`), menyalin skrip ke `/usr/local/bin`, membuat konfigurasi di `/etc/captive/config.env` (permission `600`), dan mendaftarkan service systemd.

---

### Konfigurasi

Edit file konfigurasi yang sudah terpasang di sistem:
```bash
sudo nano /etc/captive/config.env
```

Sesuaikan parameter berikut:

1. **Daftar Akun Mahasiswa**
   Pastikan urutan email dan password sejajar:
   ```bash
   USERS=(
       "user1@student.pens.ac.id"
       "user2@student.pens.ac.id"
   )
   PASSWORDS=(
       "passwordUser1"
       "passwordUser2"
   )
   ```

2. **Bot Telegram (Opsional)**
   - Buat bot lewat [@BotFather](https://t.me/BotFather) untuk mendapatkan token.
   - Ambil Chat ID tujuan (ID user atau ID grup, misal lewat [@userinfobot](https://t.me/userinfobot)):
   ```bash
   BOT_TOKEN="123456789:AAG..."
   CHAT_ID="-100xxxxxxxxx"
   ```

3. **Interface Jaringan**
   Sesuaikan dengan interface yang terhubung ke jaringan PENS (cek dengan perintah `ip link`):
   ```bash
   IFACE="eth0"   # atau enp3s0 (kabel), wlan0 (WiFi)
   ```

Simpan file (`Ctrl+O`, `Enter`, lalu `Ctrl+X`).

---

### Penggunaan & Manajemen Service

Jalankan service agar auto-login berjalan otomatis di background sejak PC dinyalakan:

```bash
# Aktifkan service auto-login
sudo systemctl enable --now captive.service

# (Opsional) Aktifkan bot Telegram listener
sudo systemctl enable --now captive-bot.service
```

Perintah pemeliharaan:
```bash
# Cek status berjalan
sudo systemctl status captive.service

# Restart service setelah ubah config
sudo systemctl restart captive.service

# Pantau log secara realtime
journalctl -u captive.service -f
```

Untuk mencoba login sekali secara manual:
```bash
sudo /usr/local/bin/captive.sh
```

---

### Command Bot Telegram

Jika `captive-bot.service` dijalankan, bot menerima perintah berikut di chat/grup yang terdaftar:
- `/cek_akun` atau `/status` : Menampilkan informasi akun yang sedang aktif dan waktu login.
- `/help` : Menampilkan ringkasan perintah bot.

---

### Uninstalasi

Jika ingin mencopot seluruh instalasi dari sistem:
```bash
sudo ./uninstall.sh
```

---

### Catatan Keamanan
Kredensial akun mahasiswa dan token bot disimpan terpisah di `/etc/captive/config.env` dengan hak akses `chmod 600` (hanya bisa dibaca root). File konfigurasi lokal juga sudah dimasukkan ke `.gitignore` sehingga tidak akan terbawa saat push ke git.
