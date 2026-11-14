-- PQ03b – SỬA LỖI: "Lưu quyền" bỏ mất 2 quyền mới (them_hang, them_ncc) vì hàm dat_quyen_nv chỉ nhận 13 quyền cũ.
-- Chỉ thay hàm dat_quyen_nv (thêm 2 khoá vào danh sách). Không đụng dữ liệu.
-- Quay lại: chạy lại hàm cũ (bỏ 'them_hang','them_ncc' khỏi danh sách) – không cần thiết.
create or replace function dat_quyen_nv(p_id uuid, p_quyen jsonb) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _bat_buoc_chu();
  if jsonb_typeof(p_quyen) <> 'object' then raise exception 'Quyền không hợp lệ'; end if;
  update nhan_vien set quyen = (
    select jsonb_object_agg(k, coalesce((p_quyen->>k)::boolean, false))
      from unnest(array['sua_gia_gio','doi_gia_ban','chiet_khau','ghi_no','vuot_han_muc','thu_no','xem_no','huy_don',
                        'tra_hang','sua_khach','nhap_toa','tra_ncc','bao_cao','them_hang','them_ncc']) k)
  where id = p_id and vai_tro <> 'chu';
end $$;
revoke execute on function dat_quyen_nv(uuid, jsonb) from public, anon;
grant execute on function dat_quyen_nv(uuid, jsonb) to authenticated;
notify pgrst, 'reload schema';
