-- ================================================================
-- TRINITRIX – Supabase SQL Setup (v4 - Clean Setup)
-- Jalankan SELURUH file ini di Supabase SQL Editor
-- ================================================================
-- URUTAN EKSEKUSI:
--   1. Extensions
--   2. Buat tabel
--   3. RLS + Policies
--   4. Functions
--   5. Data awal (rooms + documents)
-- ================================================================


-- ================================================================
-- 1. EXTENSIONS
-- ================================================================
CREATE EXTENSION IF NOT EXISTS pgcrypto;


-- ================================================================
-- 2. TABEL
-- ================================================================

CREATE TABLE IF NOT EXISTS public.rooms (
  id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text        NOT NULL,
  description text        NOT NULL DEFAULT '',
  sort_order  integer     NOT NULL DEFAULT 0,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.documents (
  id         uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  room_id    uuid        REFERENCES public.rooms(id) ON DELETE CASCADE,
  title      text        NOT NULL,
  url        text        NOT NULL,
  category   text        NOT NULL DEFAULT 'form' CHECK (category IN ('form','excel')),
  sort_order integer     NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Tabel ini hanya berisi email user yang boleh masuk ke admin panel.
-- User biasa cukup ada di Supabase Auth saja, tidak perlu di tabel ini.
CREATE TABLE IF NOT EXISTS public.admin_users (
  id           uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
  email        text        UNIQUE NOT NULL,
  display_name text        NOT NULL DEFAULT '',
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX IF NOT EXISTS admin_users_email_lower_idx ON public.admin_users (lower(email));


-- ================================================================
-- 3. ROW LEVEL SECURITY
-- ================================================================

ALTER TABLE public.rooms       ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.documents   ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.admin_users ENABLE ROW LEVEL SECURITY;

-- Hapus semua policy lama dulu agar tidak konflik saat re-run
DO $$ DECLARE r RECORD;
BEGIN
  FOR r IN SELECT policyname, tablename FROM pg_policies WHERE schemaname = 'public' LOOP
    EXECUTE format('DROP POLICY IF EXISTS %I ON public.%I', r.policyname, r.tablename);
  END LOOP;
END $$;

-- rooms: baca/tulis bebas (proteksi ada di sisi aplikasi)
CREATE POLICY "rooms_select" ON public.rooms FOR SELECT USING (true);
CREATE POLICY "rooms_insert" ON public.rooms FOR INSERT WITH CHECK (true);
CREATE POLICY "rooms_update" ON public.rooms FOR UPDATE USING (true);
CREATE POLICY "rooms_delete" ON public.rooms FOR DELETE USING (true);

-- documents: sama seperti rooms
CREATE POLICY "docs_select" ON public.documents FOR SELECT USING (true);
CREATE POLICY "docs_insert" ON public.documents FOR INSERT WITH CHECK (true);
CREATE POLICY "docs_update" ON public.documents FOR UPDATE USING (true);
CREATE POLICY "docs_delete" ON public.documents FOR DELETE USING (true);

-- admin_users: baca/tulis bebas
CREATE POLICY "admin_select" ON public.admin_users FOR SELECT USING (true);
CREATE POLICY "admin_insert" ON public.admin_users FOR INSERT WITH CHECK (true);
CREATE POLICY "admin_update" ON public.admin_users FOR UPDATE USING (true);
CREATE POLICY "admin_delete" ON public.admin_users FOR DELETE USING (true);


-- ================================================================
-- 4. FUNCTIONS
-- ================================================================

-- ----------------------------------------------------------------
-- create_user: membuat user baru di Supabase Auth
-- Dipanggil dari admin panel lewat _supa.rpc('create_user', {...})
--
-- FIX UTAMA:
--   - id di-generate eksplisit dengan gen_random_uuid()
--   - id di auth.identities pakai uuid BARU (bukan sama dengan user_id)
--   - hash password pakai pgcrypto yang sudah di-enable di step 1
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.create_user(user_email text, user_password text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'extensions', 'public', 'auth'
AS $$
DECLARE
  new_user_id  uuid;
  encrypted_pw text;
BEGIN
  user_email   := lower(user_email);
  new_user_id  := gen_random_uuid();
  encrypted_pw := crypt(user_password, gen_salt('bf', 10));

  INSERT INTO auth.users (
    instance_id,
    id,
    aud,
    role,
    email,
    encrypted_password,
    email_confirmed_at,
    confirmation_sent_at,
    confirmation_token,
    recovery_token,
    email_change_token_new,
    email_change_token_current,
    email_change,
    phone_change,
    phone_change_token,
    reauthentication_token,
    raw_app_meta_data,
    raw_user_meta_data,
    is_sso_user,
    is_anonymous,
    created_at,
    updated_at
  ) VALUES (
    '00000000-0000-0000-0000-000000000000',
    new_user_id,
    'authenticated',
    'authenticated',
    user_email,
    encrypted_pw,
    now(),
    now(),
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '',
    '{"provider":"email","providers":["email"]}',
    '{}',
    false,
    false,
    now(),
    now()
  );

  INSERT INTO auth.identities (
    id,
    user_id,
    identity_data,
    provider,
    provider_id,
    last_sign_in_at,
    created_at,
    updated_at
  ) VALUES (
    gen_random_uuid(),
    new_user_id,
    jsonb_build_object('sub', new_user_id::text, 'email', user_email, 'email_verified', true, 'phone_verified', false),
    'email',
    new_user_id::text,
    now(),
    now(),
    now()
  );

  RETURN json_build_object('success', true, 'user_id', new_user_id);
EXCEPTION
  WHEN unique_violation THEN
    RETURN json_build_object('success', false, 'error', 'Email sudah terdaftar');
  WHEN OTHERS THEN
    RETURN json_build_object('success', false, 'error', SQLERRM);
END;
$$;


-- ----------------------------------------------------------------
-- get_user_list: ambil semua user dari auth.users + flag is_admin
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_user_list()
RETURNS TABLE(
  id              uuid,
  email           text,
  created_at      timestamptz,
  last_sign_in_at timestamptz,
  is_admin        boolean
)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  RETURN QUERY
  SELECT
    u.id,
    u.email::text,
    u.created_at,
    u.last_sign_in_at,
    CASE WHEN a.email IS NOT NULL THEN true ELSE false END
  FROM auth.users u
  LEFT JOIN public.admin_users a ON lower(a.email) = lower(u.email)
  ORDER BY u.created_at DESC;
END;
$$;

-- ----------------------------------------------------------------
-- reset_user_password: reset password user berdasarkan user_id
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.reset_user_password(target_user_id uuid, new_password text)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'extensions', 'public', 'auth'
AS $$
BEGIN
  UPDATE auth.users
  SET
    encrypted_password = crypt(new_password, gen_salt('bf', 10)),
    updated_at         = now()
  WHERE id = target_user_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'User tidak ditemukan');
  END IF;

  RETURN json_build_object('success', true);
END;
$$;

-- ----------------------------------------------------------------
-- delete_user: hapus user dari auth.users secara permanen
-- ----------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.delete_user(target_user_id uuid)
RETURNS json
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'auth'
AS $$
BEGIN
  DELETE FROM auth.users WHERE id = target_user_id;

  IF NOT FOUND THEN
    RETURN json_build_object('success', false, 'error', 'User tidak ditemukan');
  END IF;

  RETURN json_build_object('success', true);
END;
$$;


-- ================================================================
-- 5. DATA AWAL – ROOMS
-- ================================================================
INSERT INTO public.rooms (id, name, sort_order) VALUES
  ('11111111-0001-0000-0000-000000000001', 'Angiografi',           1),
  ('11111111-0002-0000-0000-000000000002', 'CSSD',                 2),
  ('11111111-0003-0000-0000-000000000003', 'Depo IKO',             3),
  ('11111111-0004-0000-0000-000000000004', 'Endoskopi',            4),
  ('11111111-0005-0000-0000-000000000005', 'Hemodialisa',          5),
  ('11111111-0006-0000-0000-000000000006', 'High Care Unit (HCU)', 6),
  ('11111111-0007-0000-0000-000000000007', 'ICU',                  7),
  ('11111111-0008-0000-0000-000000000008', 'IGD',                  8),
  ('11111111-0009-0000-0000-000000000009', 'IKO',                  9),
  ('11111111-0010-0000-0000-000000000010', 'Kamar Bayi',          10),
  ('11111111-0011-0000-0000-000000000011', 'Kamar Bersalin',      11),
  ('11111111-0012-0000-0000-000000000012', 'Perawatan 2 Anak',    12),
  ('11111111-0013-0000-0000-000000000013', 'Perawatan 3',         13),
  ('11111111-0014-0000-0000-000000000014', 'Perawatan 5',         14),
  ('11111111-0015-0000-0000-000000000015', 'Poliklinik',          15),
  ('11111111-0016-0000-0000-000000000016', 'Radiologi',           16),
  ('11111111-0017-0000-0000-000000000017', 'VK Kebidanan',        17)
ON CONFLICT (id) DO UPDATE SET name = EXCLUDED.name, sort_order = EXCLUDED.sort_order;


-- ================================================================
-- 6. DATA AWAL – DOCUMENTS
-- Pakai INSERT ... ON CONFLICT DO NOTHING agar aman di-run ulang
-- ================================================================

-- Angiografi
INSERT INTO public.documents (room_id, title, url, category, sort_order) VALUES
  ('11111111-0001-0000-0000-000000000001','Data Hasil Pengukuran','https://asia1health-my.sharepoint.com/:x:/p/it_rspj/IQDKVQW8fJi7SYo_kC56XpJNAVeCAak_ydd8GFpGQdkl0oQ?e=AxnVNy','excel',0),
  ('11111111-0001-0000-0000-000000000001','1 - Suhu Ruang Tindakan','https://forms.office.com/r/SkxenCzUFQ','form',1),
  ('11111111-0001-0000-0000-000000000001','2 - Kelembaban Ruang Tindakan','https://forms.office.com/r/qiUJBawJi9','form',2),
  ('11111111-0001-0000-0000-000000000001','3 - Tekanan Udara Ruang Tindakan','https://forms.office.com/r/BSid7PpLx3','form',3),
  ('11111111-0001-0000-0000-000000000001','4 - Suhu Lemari Penyimpanan Stok Alkes CSSD','https://forms.office.com/r/xpvV1bsPFU','form',4),
  ('11111111-0001-0000-0000-000000000001','5 - Kelembaban Lemari Penyimpanan Stok Alkes CSSD','https://forms.office.com/r/E2fqugd4X0','form',5),
  ('11111111-0001-0000-0000-000000000001','6 - Suhu Lemari Es','https://forms.office.com/r/LSj8nbvgUQ','form',6),
  ('11111111-0001-0000-0000-000000000001','7 - Suhu Ruang Penyimpanan Obat','https://forms.office.com/r/fKqk19buP9','form',7),
  ('11111111-0001-0000-0000-000000000001','8 - Kelembaban Ruang Penyimpanan Obat','https://forms.office.com/r/BYazKMRnV2','form',8)
ON CONFLICT DO NOTHING;

-- CSSD
INSERT INTO public.documents (room_id, title, url, category, sort_order) VALUES
  ('11111111-0002-0000-0000-000000000002','Data Hasil Pengukuran','https://asia1health-my.sharepoint.com/:x:/p/it_rspj/IQCuN7eDLuCRSrfzC6eDiMPEAXmfbg780WNLLfKnnMw4oDs?e=5QOhj6','excel',0),
  ('11111111-0002-0000-0000-000000000002','1 - Suhu Ruang CSSD','https://forms.office.com/r/H4vj12H0jS','form',1),
  ('11111111-0002-0000-0000-000000000002','2 - Kelembaban Ruang CSSD','https://forms.office.com/r/yPVr3ApnQ2','form',2)
ON CONFLICT DO NOTHING;

-- Depo IKO
INSERT INTO public.documents (room_id, title, url, category, sort_order) VALUES
  ('11111111-0003-0000-0000-000000000003','Data Hasil Pengukuran','https://asia1health-my.sharepoint.com/:x:/p/it_rspj/IQB1qQQJV0sCSohq6_iLw-PCARZ7OD1n9L-kIkohKgojcDA?e=us7cpx','excel',0),
  ('11111111-0003-0000-0000-000000000003','1 - Suhu Ruang Depo Instalasi Kamar Operasi','https://forms.office.com/r/6JNhRuraDg','form',1),
  ('11111111-0003-0000-0000-000000000003','2 - Kelembaban Ruang Depo Instalasi Kamar Operasi','https://forms.office.com/r/TLZC1QCMm3','form',2),
  ('11111111-0003-0000-0000-000000000003','3 - Suhu Lemari Es Farmasi','https://forms.office.com/r/UUAeSd23rj','form',3)
ON CONFLICT DO NOTHING;


-- Endoskopi
INSERT INTO public.documents (room_id, title, url, category, sort_order) VALUES
  ('11111111-0004-0000-0000-000000000004','Data Hasil Pengukuran','https://asia1health-my.sharepoint.com/:x:/p/it_rspj/IQDWCANuZ19yTIq2J6fWSSvIAXVx3YCUWRGSF0kBIe3RQyQ?e=JWpQSP','excel',0),
  ('11111111-0004-0000-0000-000000000004','1 - Suhu Ruang Tindakan','https://forms.office.com/r/7FpfEvivV3','form',1),
  ('11111111-0004-0000-0000-000000000004','2 - Kelembaban Ruang Tindakan','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UNlJJNUlTS1hOREFOS0lURTZPOEJCNlUwNCQlQCNjPTEu&route=shorturl','form',2),
  ('11111111-0004-0000-0000-000000000004','3 - Tekanan Udara Ruang Tindakan','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UQ0NCVkZCVEJKTUpCRFA1T1MxWkRWNDhEMCQlQCNjPTEu&route=shorturl','form',3),
  ('11111111-0004-0000-0000-000000000004','4 - Suhu Ruang Penyimpanan Obat','https://forms.office.com/r/Guhy7hA5ah','form',4),
  ('11111111-0004-0000-0000-000000000004','5 - Kelembaban Ruang Penyimpanan Obat','https://forms.office.com/r/QqS7ZPYwSK','form',5),
  ('11111111-0004-0000-0000-000000000004','6 - Suhu Lemari Penyimpanan Stok Alkes CSSD','https://forms.office.com/r/2PjGVpT236','form',6),
  ('11111111-0004-0000-0000-000000000004','7 - Kelembaban Lemari Penyimpanan Stok Alkes CSSD','https://forms.office.com/r/dtR54suQ1G','form',7)
ON CONFLICT DO NOTHING;

-- Hemodialisa
INSERT INTO public.documents (room_id, title, url, category, sort_order) VALUES
  ('11111111-0005-0000-0000-000000000005','Data Hasil Pengukuran','https://asia1health-my.sharepoint.com/:x:/p/it_rspj/IQAhtXGgNs5TS7Qad8VM7GDtAchcXqu-GvcOVEXog2MCEZc?e=rmHgZw','excel',0),
  ('11111111-0005-0000-0000-000000000005','1 - Suhu Ruang Penyimpanan Obat','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UREhOQ0NIU0ZRRFZIV1JNSTY0SkZKUDhPQy4u&route=shorturl','form',1),
  ('11111111-0005-0000-0000-000000000005','2 - Kelembaban Ruang Penyimpanan Obat','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65URTM4UUxaREJOWVlOUVdXQk9STFRFTkRTQy4u&route=shorturl','form',2),
  ('11111111-0005-0000-0000-000000000005','3 - Suhu Lemari Es','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UNExaU1VBM1UzQTZGSjFBNTFUWVA4TUtBUC4u&route=shorturl','form',3),
  ('11111111-0005-0000-0000-000000000005','4 - Suhu Lemari Penyimpanan Stok Alkes CSSD','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UQVRXU1hIVTlKWlZaUlJZNTcyVjczVjRNVy4u&route=shorturl','form',4),
  ('11111111-0005-0000-0000-000000000005','5 - Kelembaban Lemari Penyimpanan Stok Alkes CSSD','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UQTk4VkpOTzRVM1ZTTEc1VjhNODlZRkhSRS4u&route=shorturl','form',5)
ON CONFLICT DO NOTHING;

-- High Care Unit (HCU)
INSERT INTO public.documents (room_id, title, url, category, sort_order) VALUES
  ('11111111-0006-0000-0000-000000000006','Data Hasil Pengukuran','https://asia1health-my.sharepoint.com/:x:/p/it_rspj/IQAjCsVHrhOuRavvkzpLQ2qfASPBdRhsu7-vZx1pO7KbrR4','excel',0),
  ('11111111-0006-0000-0000-000000000006','1 - Suhu Ruangan','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65URDU1U1JXR1c4Qk1HSlBPTVNZQzdaQVBaUC4u&route=shorturl','form',1),
  ('11111111-0006-0000-0000-000000000006','2 - Kelembaban Ruangan','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UNzRESVhNWERINkVNRDVOTDQ2SjYwQVJQTC4u&route=shorturl','form',2),
  ('11111111-0006-0000-0000-000000000006','3 - Suhu Ruang Isolasi Bertekanan Negatif','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65URTNaQjFRRkFKMko3S0NQODNENzA3UkRGWi4u&route=shorturl','form',3),
  ('11111111-0006-0000-0000-000000000006','4 - Kelembaban Ruang Isolasi Bertekanan Negatif','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65URjM4NDRaT0cxTTMzWlg0MEhLRUlWOU5VSi4u&route=shorturl','form',4),
  ('11111111-0006-0000-0000-000000000006','5 - Tekanan Udara Ruang Isolasi Bertekanan Negatif','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65URDk5STVKUVhOOEVMVjE1M0xDUEVWOFFBMi4u&route=shorturl','form',5),
  ('11111111-0006-0000-0000-000000000006','6 - Kelembaban Ruangan Penyimpanan Obat','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UMDVZN0xTUlFUOTFVS0NVT0FVN1ZBUEk1Si4u&route=shorturl','form',6),
  ('11111111-0006-0000-0000-000000000006','7 - Suhu Lemari Penyimpanan Stok Alkes CSSD','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65URFBSTzIxWjBSV0tURUVNMVcxUTFDN1k2VS4u&route=shorturl','form',7),
  ('11111111-0006-0000-0000-000000000006','8 - Kelembaban Lemari Penyimpanan Stok Alkes CSSD','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UMktLWjQ3S0I1TDhRTVJHNEZEWUo2MUxLRC4u&route=shorturl','form',8),
  ('11111111-0006-0000-0000-000000000006','9 - Suhu Lemari Es','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UQTdWT0ZRVzdOSzQzRzhRTVI0QU9GOUtHUy4u&route=shorturl','form',9)
ON CONFLICT DO NOTHING;


-- ICU
INSERT INTO public.documents (room_id, title, url, category, sort_order) VALUES
  ('11111111-0007-0000-0000-000000000007','Data Hasil Pengukuran','https://asia1health-my.sharepoint.com/:x:/p/it_rspj/IQCq8xFQk5U-TbOUCkKGSjEfAZ7_pWwKxyljOoaW-gd23YA?e=KarQLP','excel',0),
  ('11111111-0007-0000-0000-000000000007','1 - Suhu Ruangan Intensif','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UOFpXVDRON1pBRDhJRkVPOE5TUFozR0ZPRS4u&route=shorturl','form',1),
  ('11111111-0007-0000-0000-000000000007','2 - Kelembapan Ruangan Intensif','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UQzJBQU1VRzE0QThaRUpCS1hLUVQ1U1BWWi4u&route=shorturl','form',2),
  ('11111111-0007-0000-0000-000000000007','3 - Suhu Ruangan Isolasi','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UM1hPU0JIRERXS1VYWldTRjVMOFdKQUFSUy4u&route=shorturl','form',3),
  ('11111111-0007-0000-0000-000000000007','4 - Tekanan Udara Ruangan Isolasi','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UMjlOR0U0RE1IOUE0MEJCR1lJUkRUSTE5UC4u&route=shorturl','form',4),
  ('11111111-0007-0000-0000-000000000007','5 - Kelembapan Ruangan Penyimpanan Obat','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UOEpSVjdIOEtVRldXSzA2WTRZWVZLOVE2Qy4u&route=shorturl','form',5),
  ('11111111-0007-0000-0000-000000000007','6 - Suhu Lemari Penyimpanan Stok Alkes CSSD','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UREVBSzU2QjZaMEdYRDdYV0JTNDJCWFJKTi4u&route=shorturl','form',6),
  ('11111111-0007-0000-0000-000000000007','7 - Kelembapan Lemari Penyimpanan Stok Alkes CSSD','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UM0hFNEhJMUJMSERWUE5KSUlNU1dLNTBPWC4u&route=shorturl','form',7),
  ('11111111-0007-0000-0000-000000000007','8 - Suhu Lemari Es','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UMTVLVDBETUJaSlgxUjlEWE8wVUFCUUtWQi4u&route=shorturl','form',8)
ON CONFLICT DO NOTHING;

-- IGD
INSERT INTO public.documents (room_id, title, url, category, sort_order) VALUES
  ('11111111-0008-0000-0000-000000000008','Data Hasil Pengukuran','https://asia1health-my.sharepoint.com/:x:/p/it_rspj/IQACvOsrzxubQZG0G_oeirorAY7NmeMILXxwRZTYRSEP_ug?e=H3p9oL','excel',0),
  ('11111111-0008-0000-0000-000000000008','1 - Suhu Ruangan','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UMFFKVE1YOFcwVVU5RDhZM0FTMkZGMjVIMC4u&route=shorturl','form',1),
  ('11111111-0008-0000-0000-000000000008','2 - Kelembapan Ruangan','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UREREM0hVWkozSEVaR0ZJS0VBMDBLMEhFUy4u&route=shorturl','form',2),
  ('11111111-0008-0000-0000-000000000008','3 - Suhu Kulkas','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65URDQ2RlJFMVZTTU5HSTlLMUYwSTRNVE0yUS4u&route=shorturl','form',3),
  ('11111111-0008-0000-0000-000000000008','4 - Kelembapan R. Penyimpanan Obat','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UQlI5NVdETDhUTUhHRlY0VlhJRzFRVDkyNy4u&route=shorturl','form',4),
  ('11111111-0008-0000-0000-000000000008','5 - Suhu CSSD Supply Cabinet','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65URTY3SERUUVoyVVJOSlNJM1lBWVZGNVMyRS4u&route=shorturl','form',5),
  ('11111111-0008-0000-0000-000000000008','6 - Kelembapan CSSD Supply Cabinet','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UNzJVNVk4SDlNWlUxNUpTMDVFOVlRRTIyQy4u&route=shorturl','form',6),
  ('11111111-0008-0000-0000-000000000008','7 - Suhu R. Bertekanan Negatif','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UNVg4NDVTREZRVDBNSVFVSVhGUTBRSTdTMC4u&route=shorturl','form',7),
  ('11111111-0008-0000-0000-000000000008','8 - Tekanan Udara R. Bertekanan Negatif','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UM0gzSENWVVRFVFdQWlpRMEdNNEJGMkkxTy4u&route=shorturl','form',8)
ON CONFLICT DO NOTHING;

-- IKO
INSERT INTO public.documents (room_id, title, url, category, sort_order) VALUES
  ('11111111-0009-0000-0000-000000000009','Data Hasil Pengukuran','https://asia1health-my.sharepoint.com/:x:/p/it_rspj/IQD-fSH5BtexRJqHWhXTRhqmASpHntp2-MKK-4Z3lk6MgYk?e=ZpwOhR','excel',0),
  ('11111111-0009-0000-0000-000000000009','1 - Suhu Ruang Instalasi Kamar Operasi','https://forms.office.com/r/yePNtBT5yF','form',1),
  ('11111111-0009-0000-0000-000000000009','2 - Kelembaban Ruang Instalasi Kamar Operasi','https://forms.office.com/r/NfV9Dfjg4X','form',2),
  ('11111111-0009-0000-0000-000000000009','3 - Tekanan Udara Ruang Instalasi Kamar Operasi','https://forms.office.com/r/W9BF98C94n','form',3),
  ('11111111-0009-0000-0000-000000000009','4 - Suhu Ruang Penyimpanan Obat','https://forms.office.com/r/VP4UnjQ7Jh','form',4),
  ('11111111-0009-0000-0000-000000000009','5 - Kelembaban Ruang Penyimpanan Obat','https://forms.office.com/r/e8T4j1VbUh','form',5),
  ('11111111-0009-0000-0000-000000000009','6 - Suhu Lemari Penghangat Cairan','https://forms.office.com/r/c6T3hwizqv','form',6)
ON CONFLICT DO NOTHING;


-- Kamar Bayi
INSERT INTO public.documents (room_id, title, url, category, sort_order) VALUES
  ('11111111-0010-0000-0000-000000000010','Data Hasil Pengukuran','https://asia1health-my.sharepoint.com/:x:/p/it_rspj/IQCH6ClXXmIWRruijZd6QlfZAZCafIWZXBYA1a8RGXyGqTc?e=GnCQbl','excel',0),
  ('11111111-0010-0000-0000-000000000010','1 - Suhu Ruangan','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65URVRYVFowMUUyWlFRNTBTMDJLS1QwOFlENS4u&route=shorturl','form',1),
  ('11111111-0010-0000-0000-000000000010','2 - Kelembapan Ruangan','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UMVdVMTZWTVBaWjNKVzVTSTc0VldMUzhaSi4u&route=shorturl','form',2),
  ('11111111-0010-0000-0000-000000000010','3 - Suhu Lemari Es','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UQUlETDE3NlkyMFpYQUxHWFBJQk04ODBPVi4u&route=shorturl','form',3)
ON CONFLICT DO NOTHING;

-- Kamar Bersalin
INSERT INTO public.documents (room_id, title, url, category, sort_order) VALUES
  ('11111111-0011-0000-0000-000000000011','Data Hasil Pengukuran','https://asia1health-my.sharepoint.com/:x:/p/it_rspj/IQCRV8F9QZLhQrst7tps53jHAcRTWb_wzugXY3Up58X_Cm4?e=dsQGUw','excel',0),
  ('11111111-0011-0000-0000-000000000011','1 - Suhu Ruangan','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UNEtDQTM1NzNDTFlDTFlDRldCTkVUU0JONC4u&route=shorturl','form',1),
  ('11111111-0011-0000-0000-000000000011','2 - Kelembapan Ruangan','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UNlFVWUc0RkJCTjc5NTQzUk1ZN0xYRUlHNS4u&route=shorturl','form',2),
  ('11111111-0011-0000-0000-000000000011','3 - Suhu Lemari Penyimpanan Stok Alkes CSSD','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UNkE2RUdMRTlaMTdPNUwwVVhFV1FTTUZMNi4u&route=shorturl','form',3),
  ('11111111-0011-0000-0000-000000000011','4 - Kelembapan Lemari Penyimpanan Stok Alkes CSSD','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UQk03M1RWM0IxWDhUS1VJOVdaOUdDNVJUMC4u&route=shorturl','form',4),
  ('11111111-0011-0000-0000-000000000011','5 - Kelembapan Ruang Penyimpanan Obat','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UQURYTzA3STgwRzhPNE41WE1BU0RHMlRJTS4u&route=shorturl','form',5),
  ('11111111-0011-0000-0000-000000000011','6 - Suhu Lemari Es','https://forms.office.com/pages/responsepage.aspx?id=rwu50EO37UiZ_BaSqRJiXDSpA9Wh-PZNn-dsYaYgg65UMDhFVzRQTDg3VjlJWVhPSkNROFZNU1lBWi4u&route=shorturl','form',6)
ON CONFLICT DO NOTHING;


-- ================================================================
-- SELESAI
-- ================================================================
-- LANGKAH SETELAH SETUP:
--
-- 1. Buat admin pertama lewat Supabase Dashboard:
--    Authentication → Users → Add user (isi email + password)
--    Lalu jalankan SQL ini:
--    INSERT INTO public.admin_users (email, display_name)
--    VALUES ('email_admin@kamu.com', 'Nama Admin');
--
-- 2. Login ke admin.html → Buat User → isi email + password
--    User biasa langsung bisa login ke index.html
--
-- 3. Kalau ingin setup ulang database, jalankan dulu:
--    TRUNCATE public.documents, public.rooms, public.admin_users RESTART IDENTITY CASCADE;
--    Lalu jalankan file ini lagi dari awal.
-- ================================================================
