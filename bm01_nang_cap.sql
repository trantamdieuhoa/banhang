-- ═══════════════════════════════════════════════════════════════════
-- BM01 – TĂNG BẢO MẬT THÔNG TIN KHÁCH HÀNG (anh Tâm duyệt 13/11/2026)
-- 1. Khoá MỌI hàm với người ngoài (anon); chỉ chừa sao_luu (Apps Script sao lưu dùng mã bí mật)
--    + la_chu / la_nhan_vien / co_quyen (khoá bảng gọi tới, trả false cho người ngoài).
--    Hàm tạo mới sau này TỰ KHOÁ với người ngoài.
-- 2. Nhật ký mỗi lần sao lưu thành công (giờ, địa chỉ mạng, trình duyệt) – chủ xem trong app.
-- 3. Nhật ký AI: tự xoá nội dung tin nhắn + kết quả sau 30 ngày (giữ số lượt, token cho báo cáo).
-- 4. Tắt tài khoản "Máy marketing" (anh Tâm quyết 13/11).
-- Quay lại: bm01_quay_lai.sql
-- ═══════════════════════════════════════════════════════════════════
begin;

-- ── 1. Khoá hàm ──
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated, service_role;
grant execute on function sao_luu(text) to anon;
grant execute on function la_chu(), la_nhan_vien(), co_quyen(text) to anon;
-- Quyền mặc định "mọi người chạy được hàm" của PostgreSQL là quyền TOÀN HỆ THỐNG → phải gỡ ở cấp toàn hệ thống,
-- gỡ theo schema không ăn (test16 bắt được). Áp cho hàm do tài khoản đang chạy lệnh này (postgres) tạo sau này.
alter default privileges revoke execute on functions from public;
alter default privileges in schema public revoke execute on functions from public, anon;
alter default privileges in schema public grant execute on functions to authenticated, service_role;

-- ── 2. Nhật ký sao lưu ──
create table if not exists nhat_ky_sao_luu (
  id        bigint generated always as identity primary key,
  luc       timestamptz not null default now(),
  dia_chi   text,
  trinh_duyet text
);
alter table nhat_ky_sao_luu enable row level security;
drop policy if exists chu_xem on nhat_ky_sao_luu;
create policy chu_xem on nhat_ky_sao_luu for select to authenticated using (la_chu());
grant select on nhat_ky_sao_luu to authenticated;

create or replace function sao_luu(p_ma text) returns jsonb
language plpgsql security definer set search_path = public as $$
declare h json := nullif(current_setting('request.headers', true), '')::json;
begin
  if p_ma is null or length(p_ma) < 32 or not exists (select 1 from bi_mat where khoa = 'ma_sao_luu' and gia_tri = p_ma) then
    raise exception 'Sai mã sao lưu';
  end if;
  insert into nhat_ky_sao_luu (dia_chi, trinh_duyet)
  values (left(coalesce(h->>'cf-connecting-ip', split_part(h->>'x-forwarded-for', ',', 1), h->>'x-real-ip'), 60), left(h->>'user-agent', 200));
  delete from nhat_ky_sao_luu where luc < now() - interval '1 year';
  return _du_lieu_sao_luu();
end $$;
revoke execute on function sao_luu(text) from public;
grant execute on function sao_luu(text) to anon, authenticated;

-- Mã sao lưu mới: dùng bộ sinh số ngẫu nhiên an toàn (thay md5(random()))
create or replace function tao_ma_sao_luu() returns text
language plpgsql security definer set search_path = public as $$
declare v text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');   -- 64 ký tự, sinh ngẫu nhiên an toàn (có sẵn trong PostgreSQL)
begin
  perform _bat_buoc_chu();
  insert into bi_mat values ('ma_sao_luu', v) on conflict (khoa) do update set gia_tri = excluded.gia_tri;
  return v;
end $$;
revoke execute on function tao_ma_sao_luu() from public, anon;
grant execute on function tao_ma_sao_luu() to authenticated;

-- ── 3. Nhật ký AI: xoá nội dung sau 30 ngày (chạy mỗi lần có lượt AI mới) ──
create or replace function _xoa_tin_ai_cu() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update ai_doc_don set tin = null, ket_qua = null
   where tao_luc < now() - interval '30 days' and (tin is not null or ket_qua is not null);
  return null;
end $$;
revoke execute on function _xoa_tin_ai_cu() from public, anon;
drop trigger if exists trg_xoa_tin_ai_cu on ai_doc_don;
create trigger trg_xoa_tin_ai_cu after insert on ai_doc_don for each statement execute function _xoa_tin_ai_cu();

-- ── 4. Tắt tài khoản Máy marketing ──
update nhan_vien set hoat_dong = false where email = 'marketing@cuahang.vn' and vai_tro <> 'chu';

commit;
notify pgrst, 'reload schema';
