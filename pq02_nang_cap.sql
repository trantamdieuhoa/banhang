-- ═══════════════════════════════════════════════════════════════════
-- PQ02 – NHÂN VIÊN CÓ QUYỀN "ĐỔI GIÁ" ĐƯỢC ĐIỀN GIÁ CHO MÓN CHƯA CÓ GIÁ (anh Tâm duyệt 13/11/2026)
-- • Hàm them_gia_dau: chỉ thêm giá cho món ĐANG CHƯA CÓ GIÁ NÀO (không thêm quy cách vào món đã có giá,
--   không đổi tên / ngừng bán – vẫn chỉ chủ). Ghi tên người nhập vào ghi_chu.
-- Quay lại: pq02_quay_lai.sql
-- ═══════════════════════════════════════════════════════════════════
begin;
create or replace function them_gia_dau(p jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare v_it jsonb; v_g bigint; v_qd numeric; v_qc text; v_id text; v_n int := 0;
begin
  perform _bat_buoc_nhan_vien(); perform _can_quyen('doi_gia_ban');
  if jsonb_typeof(p) is distinct from 'array' then raise exception 'Dữ liệu không hợp lệ'; end if;
  for v_it in select * from jsonb_array_elements(p) loop
    v_id := v_it->>'hang_hoa_id'; v_qc := trim(coalesce(v_it->>'quy_cach', ''));
    v_g := _tien(v_it->>'gia_ban'); v_qd := coalesce(nullif(trim(v_it->>'so_luong_quy_doi'), '')::numeric, 1);
    if v_qc = '' then raise exception 'Chưa nhập quy cách'; end if;
    if v_g is null or v_g <= 0 then raise exception 'Giá bán không hợp lệ'; end if;
    if v_qd <= 0 then raise exception 'Số đơn vị của quy cách không hợp lệ'; end if;
    if not exists (select 1 from hang_hoa where id = v_id and dang_ban) then raise exception 'Không tìm thấy mặt hàng %', v_id; end if;
    -- Chỉ món chưa có giá nào (khoá dòng hàng để 2 người cùng điền không tạo 2 giá)
    perform 1 from hang_hoa where id = v_id for update;
    if exists (select 1 from bang_gia where hang_hoa_id = v_id and dang_ap_dung) then
      raise exception 'Món này đã có giá – muốn đổi giá bấm ✎ Sửa giá; thêm quy cách mới nhờ chủ'; end if;
    insert into bang_gia (hang_hoa_id, quy_cach, so_luong_quy_doi, gia_ban, ghi_chu)
    values (v_id, v_qc, v_qd, v_g, 'NV ' || _ten_nguoi_dung() || ' nhập ' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'DD/MM/YYYY'));
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke execute on function them_gia_dau(jsonb) from public, anon;
grant execute on function them_gia_dau(jsonb) to authenticated;
commit;
notify pgrst, 'reload schema';
