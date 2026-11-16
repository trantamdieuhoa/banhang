-- ═══════════════════════════════════════════════════════════════════
-- BM02 – CHỦ ĐẶT LẠI MẬT KHẨU NHÂN VIÊN (anh Tâm duyệt 16/11/2026)
-- • dat_lai_mat_khau_nv(id, mật khẩu mới): CHỈ chủ; CHỈ tài khoản nhân viên (không phải chủ); mật khẩu ≥ 8 ký tự,
--   không trùng tên / tên đăng nhập. Mật khẩu lưu dạng bcrypt (giống Supabase), không lưu chữ gốc ở đâu cả.
-- • Đăng xuất người đó trên MỌI máy ngay: xoá phiên (auth.sessions) + ghi nhan_vien.dang_xuat_luc;
--   mọi vé đăng nhập (JWT) cấp trước giờ đó bị coi là hết hiệu lực (la_nhan_vien, co_quyen).
-- • Nhật ký: "⚠ Chủ đặt lại mật khẩu · <tên>" (không ghi mật khẩu).
-- Quay lại: bm02_quay_lai.sql
-- ═══════════════════════════════════════════════════════════════════
begin;
alter table nhan_vien add column if not exists dang_xuat_luc timestamptz;

-- Vé đăng nhập còn hiệu lực? (cấp SAU lần chủ đặt lại mật khẩu gần nhất)
create or replace function la_nhan_vien() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from nhan_vien where id = auth.uid() and hoat_dong
                  and (dang_xuat_luc is null
                       or coalesce((auth.jwt()->>'iat')::numeric, 0) >= extract(epoch from date_trunc('second', dang_xuat_luc))))
$$;
create or replace function co_quyen(k text) returns boolean
language sql stable security definer set search_path = public as $$
  select la_chu() or (la_nhan_vien() and exists (select 1 from nhan_vien where id = auth.uid() and hoat_dong and coalesce((quyen->>k)::boolean, false)))
$$;

create or replace function dat_lai_mat_khau_nv(p_id uuid, p_mk text) returns void
language plpgsql security definer set search_path = public, extensions as $$
declare nv nhan_vien%rowtype; v_dn text;
begin
  perform _bat_buoc_chu();
  select * into nv from nhan_vien where id = p_id;
  if not found then raise exception 'Không tìm thấy nhân viên'; end if;
  if nv.vai_tro = 'chu' then raise exception 'Không đặt lại mật khẩu tài khoản chủ ở đây (chủ tự đổi trong Thêm → Đổi mật khẩu)'; end if;
  if length(coalesce(p_mk, '')) < 8 then raise exception 'Mật khẩu mới phải từ 8 ký tự'; end if;
  v_dn := split_part(lower(coalesce(nv.email, '')), '@', 1);
  if lower(p_mk) in (lower(coalesce(nv.ten, '')), v_dn, lower(coalesce(nv.email, ''))) then
    raise exception 'Mật khẩu không được trùng tên hoặc tên đăng nhập'; end if;
  update auth.users set encrypted_password = crypt(p_mk, gen_salt('bf', 10)), updated_at = now() where id = p_id;
  if not found then raise exception 'Không tìm thấy tài khoản đăng nhập của nhân viên này'; end if;
  delete from auth.sessions where user_id = p_id;            -- thu hồi phiên → không làm mới vé được nữa
  update nhan_vien set dang_xuat_luc = now() where id = p_id;  -- vé đang cầm hết hiệu lực ngay
  perform _nk_ghi('nhan_vien', 'MATKHAU', p_id::text, 'he_thong', '⚠ Chủ đặt lại mật khẩu', 3,
                  nv.ten || coalesce(' (' || nv.email || ')', '') || ' · đăng xuất trên mọi máy', null, null, null, null);
end $$;
revoke execute on function dat_lai_mat_khau_nv(uuid, text) from public, anon;
grant execute on function dat_lai_mat_khau_nv(uuid, text) to authenticated;

-- Nhật ký: cột dang_xuat_luc tự cập nhật, không tính là "sửa nhân viên"
create or replace function _nk_bo_cot(t text) returns text[] language sql stable as $$
  select array['sua_luc', 'tao_luc', 'ton_kho', 'nhac_no_luc', 'da_giao', 'giao_luc', 'nguoi_giao', 'dang_xuat_luc']
    || case t when 'yeu_cau_duyet' then array['da_dung', 'don_hang_id'] else '{}'::text[] end
    || case when t = 'hang_hoa' and _nk_co_bang('phieu_nhap') then array['gia_von'] else '{}'::text[] end $$;
revoke execute on function _nk_bo_cot(text) from public, anon, authenticated;
commit;
notify pgrst, 'reload schema';
