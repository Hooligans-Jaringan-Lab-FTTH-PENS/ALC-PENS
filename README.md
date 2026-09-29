# 🌐 AutoLogin Captive Portal PENS (Bergilir & Notifikasi Telegram)

[![Bash](https://img.shields.io/badge/Language-Bash-4EAA25?style=flat&logo=gnu-bash&logoColor=white)](https://www.gnu.org/software/bash/)
[![Linux](https://img.shields.io/badge/Platform-Linux-FCC624?style=flat&logo=linux&logoColor=black)](https://kernel.org)
[![Systemd](https://img.shields.io/badge/Service-Systemd-black?style=flat&logo=systemd)](https://systemd.io/)
[![Telegram](https://img.shields.io/badge/Bot-Telegram-2CA5E0?style=flat&logo=telegram&logoColor=white)](https://core.telegram.org/bots)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

Sistem otomatisasi login untuk **Captive Portal Jaringan Kampus PENS** (*Politeknik Elektronika Negeri Surabaya*) yang dilengkapi dengan **rotasi akun bergilir**, **deteksi auto-fallback jika kuota penuh**, **rekap riwayat mingguan**, serta **monitoring interaktif via Bot Telegram**.

---

## 📌 Latar Belakang Masalah

Di lingkungan kampus PENS, koneksi internet seringkali terputus karena:
1. Sesi login captive portal memiliki batas waktu (sering *session expired* / *timeout*).
2. Setiap akun mahasiswa memiliki batas maksimal **3 login bersamaan** (`"You are already logged in 3 times"`).
3. Sangat merepotkan jika kita memiliki PC Lab, server riset, atau Raspberry Pi yang membutuhkan koneksi internet stabil 24/7 tanpa harus membuka browser secara manual setiap kali jaringan terputus.

**Solusi:** Skrip ini memonitor koneksi internet setiap 30 detik. Jika internet terputus, ia akan melakukan otentikasi otomatis menggunakan daftar akun mahasiswa secara bergilir setiap hari dan otomatis beralih ke akun cadangan jika akun utama sedang penuh atau gagal.

---

## ✨ Fitur Unggulan

- 🔄 **Rotasi Akun Harian**: Menggilir penggunaan akun secara adil setiap berganti hari agar tidak membebani satu akun saja.
- 🛡️ **Auto-Fallback Cerdas**: Jika suatu akun mencapai batas kuota 3 perangkat atau login gagal, skrip otomatis mencoba akun berikutnya sampai terhubung.
- ⚡ **Deteksi Ringan & Senyap (*Silent Check*)**: Menggunakan request ringan `http://www.gstatic.com/generate_204`. Jika internet aktif (HTTP 204), proses langsung keluar tanpa membebani CPU & RAM.
- 📊 **Rekap Mingguan**: Mencatat riwayat 7 hari terakhir (hari, jam, dan akun yang login).
- 📲 **Notifikasi Telegram**: Mengirim pemberitahuan otomatis ke grup/chat Telegram saat terjadi pergantian akun atau login harian baru.
- 🤖 **Bot Listener Interaktif**: Mendukung perintah seperti `/cek_akun` atau `/status` langsung dari Telegram untuk mengecek akun siapa yang sedang aktif di PC/server.
- ⚙️ **Service Background (Systemd)**: Berjalan otomatis sejak sistem Linux dinyalakan (*boot*) dan memiliki fitur *auto-restart* jika terjadi kendala.
- 🔒 **Aman untuk Kolaborasi**: Kredensial akun dan token bot disimpan terpisah di file konfigurasi lokal dengan permission ketat (`chmod 600`), sehingga aman dari risiko kebocoran saat di-push ke GitHub.

---

## 📁 Struktur Direktori

```text
AutoLoginCaptive/
├── .gitignore                     # Mencegah file konfigurasi sensitif ter-upload ke Git
├── LICENSE                        # Lisensi open-source (MIT)
├── README.md                      # Dokumentasi lengkap proyek
├── install.sh                     # Skrip instalasi otomatis sekali jalan
├── uninstall.sh                   # Skrip pembersihan/pencopotan layanan
├── config.env.example             # Template contoh konfigurasi
├── scripts/
│   ├── captive.sh                 # Skrip inti (pengecekan koneksi, rotasi, & auto-login)
│   └── telegram_bot_listener.sh   # Skrip listener polling Bot Telegram (/cek_akun)
└── systemd/
    ├── captive.service            # Unit systemd untuk auto-login berkala (30s)
    └── captive-bot.service        # Unit systemd untuk listener bot Telegram
```

---

## 📋 Prasyarat Sistem

- Sistem Operasi berbasis **Linux** (Ubuntu, Debian, Raspberry Pi OS, Arch, Kali, dll).
- Paket sistem dasar: `curl`, `jq`, `iproute2` (skrip `install.sh` akan membantu menginstalnya secara otomatis jika belum ada).
- Akun mahasiswa PENS (`@*.student.pens.ac.id`) yang aktif.

---

## 🚀 Panduan Instalasi Cepat

### 1. Clone Repository
```bash
git clone https://github.com/USERNAME_ANDA/AutoLoginCaptive.git
cd AutoLoginCaptive
```

### 2. Jalankan Installer
Beri izin eksekusi lalu jalankan skrip instalasi dengan `sudo`:
```bash
chmod +x install.sh uninstall.sh scripts/*.sh
sudo ./install.sh
```

Skrip ini akan secara otomatis:
- Memeriksa dan menginstal `curl` serta `jq`.
- Memasang konfigurasi aman di `/etc/captive/config.env` (dengan hak akses `600`).
- Menyalin skrip ke `/usr/local/bin/`.
- Memasang dan me-reload unit layanan **systemd**.

---

## ⚙️ Konfigurasi Akun & Bot

Buka file konfigurasi yang telah terpasang:
```bash
sudo nano /etc/captive/config.env
```

### 1. Menambahkan Akun Mahasiswa
Masukkan daftar email mahasiswa dan password yang sejajar urutannya:
```bash
USERS=(
    "andi@te.student.pens.ac.id"
    "dary@iet.student.pens.ac.id"
    "mahasiswa3@it.student.pens.ac.id"
)

PASSWORDS=(
    "PasswordAndi"
    "PasswordDary"
    "PasswordMhs3"
)
```

### 2. Menghubungkan ke Bot Telegram (Opsional tapi Direkomendasikan)
1. Buka aplikasi Telegram, cari akun **[@BotFather](https://t.me/BotFather)**.
2. Ketik `/newbot`, ikuti instruksi, lalu salin **HTTP API Token** yang diberikan ke variabel `BOT_TOKEN`.
3. Buat grup Telegram (atau chat pribadi dengan bot), lalu cari Chat ID Anda:
   - Anda bisa menambahkan bot pembantu seperti **[@userinfobot](https://t.me/userinfobot)** ke grup untuk melihat Chat ID (biasanya diawali tanda minus `-` untuk grup).
4. Masukkan ke konfigurasi:
   ```bash
   BOT_TOKEN="1234567890:ABCdefGHIjklMNOpqrSTUvwxYZ"
   CHAT_ID="-1001234567890"
   ```

### 3. Mengatur Interface Jaringan
Pastikan nama interface sesuai dengan yang terhubung ke jaringan kampus:
- Untuk koneksi kabel LAN: umumnya `eth0`, `enp3s0`, atau `eno1`.
- Untuk koneksi Wi-Fi: umumnya `wlan0` atau `wlp2s0`.
- Cek nama interface Anda dengan perintah: `ip link` atau `nmcli device`.
```bash
IFACE="eth0"
```

Simpan file dengan menekan `Ctrl + O`, `Enter`, lalu keluar dengan `Ctrl + X`.

---

## 🧪 Uji Coba Manual

Sebelum menyalakan layanan otomatis, Anda bisa menguji apakah skrip berjalan dengan benar:

```bash
# Jalankan skrip auto-login sekali
sudo /usr/local/bin/captive.sh
```

Jika jaringan sedang belum terotentikasi, skrip akan melakukan login dan mengirimkan notifikasi ke Telegram.

---

## 🖥️ Menjalankan Service di Latar Belakang

Aktifkan service agar berjalan otomatis dan selalu hidup saat komputer dinyalakan:

```bash
# 1. Aktifkan service auto-login (memeriksa koneksi setiap 30 detik)
sudo systemctl enable --now captive.service

# 2. (Opsional) Aktifkan service bot Telegram listener
sudo systemctl enable --now captive-bot.service
```

### Memeriksa Status Layanan
```bash
# Cek status auto-login
sudo systemctl status captive.service

# Cek status bot listener
sudo systemctl status captive-bot.service
```

### Melihat Log Realtime
```bash
journalctl -u captive.service -f
```

---

## 🤖 Perintah Bot Telegram

Jika `captive-bot.service` aktif, Anda dan anggota grup dapat mengirim perintah berikut langsung ke bot:

| Perintah | Keterangan |
| :--- | :--- |
| `/cek_akun` | Mengecek akun mahasiswa yang saat ini sedang aktif login di sistem |
| `/status` | Alias dari `/cek_akun` |
| `/help` | Menampilkan panduan bantuan perintah bot |

---

## 🗑️ Cara Uninstal

Jika Anda ingin mencopot seluruh skrip dan service dari sistem:
```bash
sudo ./uninstall.sh
```
Skrip akan menghentikan seluruh service, menghapus file unit systemd, dan menanyakan apakah Anda ingin menghapus log dan file konfigurasi.

---

## 🛡️ Keamanan & Privasi

> [!WARNING]
> **PENTING UNTUK KONTRIBUTOR & PENGGUNA GITHUB:**
> File `config.env` berisi password akun mahasiswa dan token bot Telegram Anda. File ini **SUDAH** didaftarkan di [.gitignore](.gitignore) secara default.
> **JANGAN PERNAH** menghapus baris `config.env` dari `.gitignore` atau mengunggah password asli ke commit Git publik!

---

## 🤝 Kontribusi

Kontribusi berupa perbaikan bug, penambahan fitur, atau optimasi sangat disambut!
1. Fork repository ini
2. Buat branch fitur baru (`git checkout -b fitur/fitur-baru`)
3. Commit perubahan (`git commit -m 'Menambahkan fitur baru'`)
4. Push ke branch (`git push origin fitur/fitur-baru`)
5. Buat **Pull Request**

---

## 📄 Lisensi

Proyek ini dirilis di bawah lisensi [MIT License](LICENSE). Bebas digunakan, dimodifikasi, dan dibagikan untuk sesama mahasiswa.
