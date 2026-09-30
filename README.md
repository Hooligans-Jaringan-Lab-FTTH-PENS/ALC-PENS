# AutoLogin Captive PENS

Skrip auto-login captive portal PENS (`iac7.pens.ac.id:8009`) untuk Linux. Dilengkapi fitur rotasi multi-akun harian, failover otomatis saat akun terkena batas limit (*logged in 3 times*), dan bot listener Telegram untuk monitoring.

Dibuat untuk kebutuhan PC Lab, server riset, atau mini PC (seperti Raspberry Pi) yang butuh koneksi internet kampus tetap aktif 24/7 tanpa harus buka browser untuk login ulang manual.

---

### Cara Kerja
1. Pengecekan status internet dilakukan berkala (default setiap 30 detik) via request ke `http://www.gstatic.com/generate_204`. Jika respon `204`, skrip langsung keluar tanpa membebani sistem.
2. Jika koneksi terputus, skrip mengirim POST login ke captive portal PENS menggunakan akun yang dijadwalkan hari itu.
3. Jika akun tersebut gagal atau muncul notifikasi *"You are already logged in 3 times"*, skrip otomatis beralih (*fallback*) ke akun cadangan berikutnya di daftar sampai berhasil terhubung.
4. Riwayat akun aktif dicatat dalam rekap mingguan (`/var/local/rekap_mingguan.txt`).
5. Terintegrasi dengan Bot Telegram lengkap dengan **tombol menu interaktif** untuk monitoring status, histori rotasi, logout & login ulang, cek URL portal, serta pemantauan spesifikasi/resource VM.

---

### Struktur File

```text
AutoLoginCaptive/
├── install.sh                  # Skrip installer otomatis
├── uninstall.sh                # Skrip uninstaller
├── config.env.example          # Contoh file konfigurasi (dummy)
├── scripts/
│   ├── captive.sh              # Skrip utama cek internet & auto-login
│   ├── cek_captive.sh          # Skrip ringkas cek akun aktif di CLI VM
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

3. **Interface Jaringan (`IFACE`)**
   Skrip ini secara bawaan menggunakan koneksi **kabel LAN** dengan interface `eth0` (sesuai setup PC di lab pembuat). Jika Anda menggunakannya di lab atau perangkat lain, sesuaikan nilai `IFACE`:
   - **Koneksi Kabel (LAN)**: Jika di lab Anda menggunakan LAN, sesuaikan nama interfacenya (biasanya `eth0`, `enp3s0`, atau `eno1`).
   - **Koneksi Wi-Fi**: Jika perangkat/laptop Anda terhubung menggunakan Wi-Fi kampus, ubah interfacenya ke perangkat wireless Anda, misalnya `wlan0`, `wlan1`, `wlp2s0`, dan seterusnya.
   
   > 💡 **Cara cek nama interface:** Jalankan perintah `ip link` atau `ip a` di terminal, lalu perhatikan nama interface yang statusnya `state UP`.
   ```bash
   IFACE="eth0"   # ganti ke wlan0 / wlan1 jika pakai Wi-Fi
   ```

4. **URL Captive Portal & Port (`LOGIN_URL`)**
   Nilai bawaan skrip ini mengarah ke `https://iac7.pens.ac.id:8009/index.php?zone=misc` karena disesuaikan dengan koneksi LAN di lab pembuat. Namun, **setiap gedung, lab, lantai, maupun access point Wi-Fi di PENS memiliki host `iac` dan port yang berbeda-beda** (misalnya `iac1`, `iac2`, `iac7`, `iac10` dengan port `8008`, `8009`, dll).

   **Cara mengetahui URL portal di lokasi Anda:**
   1. Hubungkan perangkat ke jaringan kampus (baik lewat kabel LAN maupun Wi-Fi).
   2. Buka browser dan kunjungi sembarang situs HTTP (misal: `http://neverssl.com` atau `http://google.com`).
   3. Browser akan otomatis dialihkan (*redirect*) ke portal login PENS.
   4. Perhatikan address bar browser Anda, lalu salin URL lengkapnya ke konfigurasi:
      ```bash
      LOGIN_URL="https://iac7.pens.ac.id:8009/index.php?zone=misc" # sesuaikan iac dan port Anda
      ```
   *(Header `ORIGIN` akan otomatis diekstrak oleh skrip dari `LOGIN_URL` tersebut).*

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

Untuk cek akun aktif & status koneksi langsung dari terminal VM:
```bash
cek_captive.sh
# atau:
/cek_captive.sh
```

---

### Menu Tombol & Perintah Bot Telegram

Bot ini dilengkapi fitur **Tombol Interaktif (Inline Keyboard)** yang menempel langsung di bawah balon pesan chat Telegram, sehingga Anda dan rekan di grup cukup sekali klik tanpa perlu repot mengetik perintah teks:

```text
┌─────────────────────────┬─────────────────────────┐
│    📊 Status Captive    │    📜 Riwayat Login     │
├─────────────────────────┼─────────────────────────┤
│ 🚪 Logout & Login Ulang │      🌐 URL Portal      │
├─────────────────────────┼─────────────────────────┤
│    ⚙️ Status Service    │   🖥 Info VM & Server   │
└─────────────────────────┴─────────────────────────┘
```

| Tombol Menu | Perintah Teks | Fungsi |
| :--- | :--- | :--- |
| **`📊 Status Captive`** | `/status` / `/cek_akun` | Cek akun aktif, status internet, riwayat rotasi, & ringkasan VM |
| **`📜 Riwayat Login`** | `/riwayat` / `/rekap` | **Lihat daftar histori akun siapa saja & kapan pernah login** |
| **`🚪 Logout & Login Ulang`** | `/logout` | Logout sesi aktif portal & login ulang (tetap gunakan akun ini jika masih valid) |
| **`🌐 URL Portal`** | `/url` / `/portal` | Minta URL portal login aktif & link logout manual |
| **`⚙️ Status Service`** | `/service` / `/cek_service` | Cek apakah service captive sedang 🟢 HIDUP atau 🔴 MATI |
| **`🖥 Info VM & Server`** | `/vm` / `/vmstatus` | Pantau kondisi & spesifikasi lengkap VM (CPU, RAM, Disk, Uptime, IP) |

> 💡 **Notifikasi Otomatis Startup VM:** Setiap kali VM dinyalakan atau service bot di-restart, bot akan otomatis mengirimkan notifikasi spesifikasi dan status VM ke Telegram lengkap dengan tombol menu interaktif jika opsi `NOTIFY_VM_ON_START="true"` diaktifkan di konfigurasi.

---

### Uninstalasi

Jika ingin mencopot seluruh instalasi dari sistem:
```bash
sudo ./uninstall.sh
```

---

### Catatan Keamanan
Kredensial akun mahasiswa dan token bot disimpan terpisah di `/etc/captive/config.env` dengan hak akses `chmod 600` (hanya bisa dibaca root). File konfigurasi lokal juga sudah dimasukkan ke `.gitignore` sehingga tidak akan terbawa saat push ke git.

