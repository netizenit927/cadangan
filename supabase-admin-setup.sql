-- ================================================================
-- TRINITRIX - RS Premier Jatinegara
-- DATABASE SETUP LENGKAP (dari awal)
--
-- Cara pakai:
--   1. Buka Supabase Dashboard → SQL Editor → New Query
--   2. Paste seluruh isi file ini
--   3. Klik "Run" (atau tekan Ctrl+Enter)
--   4. Setelah selesai, ikuti instruksi di bagian akhir
-- ================================================================


-- ================================================================
-- BAGIAN 1: HAPUS SEMUA YANG ADA (kalau mau reset total)
-- Aktifkan blok DROP di bawah kalau mau mulai dari nol bersih.
-- Kalau database masih kosong, skip bagian ini.
-- ================================================================

/*
DROP TABLE IF EXISTS public.forms CASCADE;
DROP TABLE IF EXISTS public.units CASCADE;
DROP TABLE IF EXISTS public.admin_users CASCADE;
*/


-- ================================================================
-- BAGIAN 2: BUAT TABEL
-- ================================================================

-- ----------------------------------------------------------------
-- 2a. Tabel: units
--     Menyimpan kategori / unit kerja rumah sakit.
--     Contoh: IGD, Farmasi, ICU, Laboratorium, dll.
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.units (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name       text        NOT NULL UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.units      IS 'Kategori / unit kerja rumah sakit';
COMMENT ON COLUMN public.units.name IS 'Nama unit, harus unik';


-- ----------------------------------------------------------------
-- 2b. Tabel: forms
--     Menyimpan dokumen / laporan milik setiap unit.
--     Setiap dokumen punya nama, link, dan urutan tampil.
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.forms (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  unit_id     uuid        NOT NULL REFERENCES public.units(id) ON DELETE CASCADE,
  name        text        NOT NULL,
  link        text        NOT NULL,
  sort_order  integer     NOT NULL DEFAULT 1,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS forms_unit_id_idx ON public.forms(unit_id);
CREATE INDEX IF NOT EXISTS forms_sort_idx    ON public.forms(unit_id, sort_order);

COMMENT ON TABLE  public.forms            IS 'Dokumen / laporan milik setiap unit';
COMMENT ON COLUMN public.forms.unit_id    IS 'FK ke units.id';
COMMENT ON COLUMN public.forms.name       IS 'Nama dokumen / form';
COMMENT ON COLUMN public.forms.link       IS 'URL dokumen (Google Form, Spreadsheet, dll)';
COMMENT ON COLUMN public.forms.sort_order IS 'Urutan tampil di dalam unit';


-- ----------------------------------------------------------------
-- 2c. Tabel: admin_users
--     Daftar email yang berhak mengakses Admin Panel.
--     Login tetap lewat Supabase Auth, tapi akses admin
--     divalidasi ke tabel ini.
-- ----------------------------------------------------------------
CREATE TABLE IF NOT EXISTS public.admin_users (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  email      text        NOT NULL UNIQUE,
  role       text        NOT NULL DEFAULT 'admin'
                         CHECK (role IN ('admin', 'superadmin')),
  created_at timestamptz NOT NULL DEFAULT now()
);

COMMENT ON TABLE  public.admin_users      IS 'Whitelist email admin panel';
COMMENT ON COLUMN public.admin_users.role IS 'admin = akses biasa, superadmin = akses penuh';


-- ================================================================
-- BAGIAN 3: ROW LEVEL SECURITY (RLS)
-- ================================================================

-- ----------------------------------------------------------------
-- units
-- ----------------------------------------------------------------
ALTER TABLE public.units ENABLE ROW LEVEL SECURITY;

-- Siapapun yang sudah login bisa baca (untuk halaman publik user)
CREATE POLICY "units: authenticated read"
  ON public.units FOR SELECT
  TO authenticated
  USING (true);

-- Hanya admin yang bisa tambah
CREATE POLICY "units: admin insert"
  ON public.units FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.admin_users
      WHERE email = (auth.jwt() ->> 'email')
    )
  );

-- Hanya admin yang bisa ubah
CREATE POLICY "units: admin update"
  ON public.units FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.admin_users
      WHERE email = (auth.jwt() ->> 'email')
    )
  );

-- Hanya admin yang bisa hapus
CREATE POLICY "units: admin delete"
  ON public.units FOR DELETE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.admin_users
      WHERE email = (auth.jwt() ->> 'email')
    )
  );


-- ----------------------------------------------------------------
-- forms
-- ----------------------------------------------------------------
ALTER TABLE public.forms ENABLE ROW LEVEL SECURITY;

-- Semua user login bisa baca
CREATE POLICY "forms: authenticated read"
  ON public.forms FOR SELECT
  TO authenticated
  USING (true);

-- Hanya admin yang bisa tambah
CREATE POLICY "forms: admin insert"
  ON public.forms FOR INSERT
  TO authenticated
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM public.admin_users
      WHERE email = (auth.jwt() ->> 'email')
    )
  );

-- Hanya admin yang bisa ubah
CREATE POLICY "forms: admin update"
  ON public.forms FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.admin_users
      WHERE email = (auth.jwt() ->> 'email')
    )
  );

-- Hanya admin yang bisa hapus
CREATE POLICY "forms: admin delete"
  ON public.forms FOR DELETE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM public.admin_users
      WHERE email = (auth.jwt() ->> 'email')
    )
  );


-- ----------------------------------------------------------------
-- admin_users
-- ----------------------------------------------------------------
ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;

-- Admin hanya bisa baca record miliknya sendiri
-- (dipakai oleh admin.html untuk validasi login)
CREATE POLICY "admin_users: read own record"
  ON public.admin_users FOR SELECT
  TO authenticated
  USING (
    email = (auth.jwt() ->> 'email')
  );

-- Tidak ada policy insert/update/delete untuk admin_users via client.
-- Manajemen admin hanya boleh lewat SQL Editor Supabase (server-side).


-- ================================================================
-- BAGIAN 4: DATA CONTOH (opsional, bisa dihapus)
-- ================================================================

INSERT INTO public.units (name) VALUES
  ('IGD'),
  ('Farmasi'),
  ('ICU'),
  ('Laboratorium'),
  ('Radiologi'),
  ('Rawat Inap'),
  ('Rawat Jalan'),
  ('Rekam Medis'),
  ('Gizi'),
  ('Kamar Operasi')
ON CONFLICT (name) DO NOTHING;


INSERT INTO public.forms (unit_id, name, link, sort_order)
SELECT u.id, 'Form Laporan Harian', 'https://forms.google.com', 1
FROM public.units u WHERE u.name = 'IGD'
ON CONFLICT DO NOTHING;

INSERT INTO public.forms (unit_id, name, link, sort_order)
SELECT u.id, 'Rekap Bulanan IGD', 'https://docs.google.com/spreadsheets', 2
FROM public.units u WHERE u.name = 'IGD'
ON CONFLICT DO NOTHING;

INSERT INTO public.forms (unit_id, name, link, sort_order)
SELECT u.id, 'Form Permintaan Obat', 'https://forms.google.com', 1
FROM public.units u WHERE u.name = 'Farmasi'
ON CONFLICT DO NOTHING;


-- ================================================================
-- BAGIAN 5: DAFTARKAN AKUN ADMIN
-- ================================================================
--
-- WAJIB dilakukan sebelum bisa login ke admin.html:
--
-- Langkah A — Buat user di Supabase Auth:
--   Dashboard → Authentication → Users → "Add User"
--   Isi email dan password. Aktifkan "Auto Confirm User".
--
-- Langkah B — Masukkan email ke tabel admin_users di bawah,
--   lalu jalankan query ini (atau jalankan terpisah):
--
-- ----------------------------------------------------------------

INSERT INTO public.admin_users (email, role)
VALUES
  ('admin@rspj.com', 'superadmin')
  -- ('admin2@rspj.com', 'admin'),   -- tambah admin lain di sini
ON CONFLICT (email) DO NOTHING;


-- ================================================================
-- SELESAI.
-- Akses admin panel di: https://<domain-kamu>/admin.html
-- ================================================================
