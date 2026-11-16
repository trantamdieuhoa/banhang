-- QUAY LẠI BM02: bỏ hàm đặt lại mật khẩu; la_nhan_vien, co_quyen, _nk_bo_cot về như trước; bỏ cột dang_xuat_luc.
-- Mật khẩu đã đặt lại vẫn giữ (nhân viên dùng mật khẩu mới).
begin;
drop function if exists dat_lai_mat_khau_nv(uuid, text);
create or replace function la_nhan_vien() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from nhan_vien where id = auth.uid() and hoat_dong)
$$;
create or replace function co_quyen(k text) returns boolean
language sql stable security definer set search_path = public as $$
  select la_chu() or exists (select 1 from nhan_vien where id = auth.uid() and hoat_dong and coalesce((quyen->>k)::boolean, false))
$$;
create or replace function _nk_bo_cot(t text) returns text[] language sql stable as $$
  select array['sua_luc', 'tao_luc', 'ton_kho', 'nhac_no_luc', 'da_giao', 'giao_luc', 'nguoi_giao']
    || case t when 'yeu_cau_duyet' then array['da_dung', 'don_hang_id'] else '{}'::text[] end
    || case when t = 'hang_hoa' and _nk_co_bang('phieu_nhap') then array['gia_von'] else '{}'::text[] end $$;
revoke execute on function _nk_bo_cot(text) from public, anon, authenticated;
alter table nhan_vien drop column if exists dang_xuat_luc;
commit;
notify pgrst, 'reload schema';
