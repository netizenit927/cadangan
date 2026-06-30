# TRINITRIX

Portal PWA untuk monitoring data pengukuran suhu, kelembaban, dan tekanan udara di ruangan RSPJ (Rumah Sakit Pusat Jantung).

## Fitur

- **Portal publik** (`index.html`) — Login, browse kategori ruangan, akses link Microsoft Forms (input data) & Excel SharePoint (hasil pengukuran)
- **Panel admin** (`admin.html`) — CRUD kategori/ruangan, CRUD link form, buat/hapus/reset user, grant/revoke admin
- **PWA** — Service worker offline caching, installable di mobile

## Tech Stack

| Komponen | Teknologi |
|---|---|
| Frontend | HTML5 + JavaScript (vanilla), Tailwind CSS (CDN) |
| Backend | Supabase (PostgreSQL + Auth + RLS) |
| Hosting | Vercel |
| PWA | Service Worker + Web Manifest |

## Struktur Proyek

```
├── index.html          # Portal publik (login + browser kategori/dokumen)
├── admin.html          # Panel admin (4 halaman: kategori, tambah form, buat user, daftar user)
├── supabase_setup.sql  # Full SQL schema (tabel, policy, RPC function, seed data)
├── sw.js               # Service worker offline caching
├── manifest.json       # PWA manifest
├── vercel.json         # Vercel deploy config (clean URL + security headers)
├── trinitrix.png       # App icon
└── README.md
```

## Setup Database (Supabase)

### 1. Buka SQL Editor

Login ke [Supabase Dashboard](https://supabase.com/dashboard), pilih project, lalu buka **SQL Editor**.

### 2. Jalankan SQL setup

Copy-paste seluruh isi `supabase_setup.sql` ke SQL Editor, lalu klik **Run**.

### 3. Buat admin pertama

Buka **Authentication → Users → Add user**, isi email + password.

Lalu jalankan SQL ini:

```sql
INSERT INTO public.admin_users (email, display_name)
VALUES ('admin@rumahsakit.com', 'Nama Admin');
```

Setelah itu admin bisa login ke `admin.html` dan membuat user lain.

## Menjalankan Lokal

Cukup serve file statis dengan HTTP server apapun:

```bash
python3 -m http.server 8080
# atau
npx serve .
```

Buka `http://localhost:8080` di browser.

> Output tanpa HTTP server (double-click HTML) bisa menyebabkan service worker / Supabase Auth gagal.

## Deploy ke Vercel

1. Push project ke GitHub
2. Import repo di [vercel.com](https://vercel.com)
3. `vercel.json` sudah ada — clean URL (`/admin` → `/admin.html`) dan security headers otomatis

## Supabase RPC Functions

| Function | Digunakan Oleh | Keterangan |
|---|---|---|
| `create_user(email, password)` | Admin panel → Buat User | Membuat user baru di `auth.users` |
| `get_user_list()` | Admin panel → Daftar User | Mengembalikan semua user + flag is_admin |
| `reset_user_password(user_id, password)` | Admin panel → Reset Pass | Mengganti password user |
| `delete_user(user_id)` | Admin panel → Hapus | Menghapus user dari `auth.users` |

Semua function menggunakan `SECURITY DEFINER` untuk bypass RLS.

## Catatan

- Semua email dinormalisasi ke **lowercase** saat login dan insert untuk mencegah case-sensitivity bug
- `verifyAdmin()` di `admin.html` menggunakan `.ilike()` untuk case-insensitive admin check
- Supabase `auth.identities.email` dan `auth.users.confirmed_at` adalah **GENERATED columns** — tidak perlu di-insert manual
- Kolom `is_sso_user` dan `is_anonymous` wajib diisi `false` pada Supabase versi terbaru
- Tabel `admin_users` punya unique index pada `lower(email)` untuk cegah duplikat beda case
