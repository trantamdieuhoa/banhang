-- QUAY LẠI PQ04: bỏ hàm nv_sua_hang + quyền sua_hang; dat_quyen_nv, _ten_quyen, _nk_mo_ta về như trước. Món NV đã sửa giữ nguyên.
begin;
drop function if exists nv_sua_hang(jsonb);
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

create or replace function _ten_quyen(k text) returns text
language sql immutable as $$
  select case k when 'sua_gia_gio' then 'sửa giá trong giỏ' when 'doi_gia_ban' then 'đổi giá bảng giá' when 'chiet_khau' then 'chiết khấu'
    when 'ghi_no' then 'bán ghi nợ' when 'vuot_han_muc' then 'vượt hạn mức nợ' when 'thu_no' then 'thu tiền nợ' when 'xem_no' then 'xem nợ khách'
    when 'huy_don' then 'huỷ đơn' when 'tra_hang' then 'trả hàng / đổi thưởng' when 'sua_khach' then 'thêm/sửa khách'
    when 'nhap_toa' then 'nhập toa, kiểm kho' when 'tra_ncc' then 'trả tiền NCC' when 'bao_cao' then 'báo cáo, chốt sổ'
    when 'them_hang' then 'thêm mặt hàng mới' when 'them_ncc' then 'thêm/sửa nhà cung cấp' else k end
$$;
revoke execute on function _ten_quyen(text) from public, anon;

create or replace function _nk_mo_ta(t text, op text, o jsonb, n jsonb, d jsonb,
  out loai text, out viec text, out muc int, out tom text, out tien bigint)
language plpgsql stable security definer set search_path = public as $$
declare r jsonb := coalesce(n, o); ten text; kh text;
begin
  muc := 2;
  case t
  when 'hang_hoa' then
    loai := 'hang'; tom := r->>'ten';
    viec := case op when 'INSERT' then 'Thêm mặt hàng' when 'DELETE' then 'Xoá mặt hàng'
                 else case when d ? 'dang_ban' then case when (n->>'dang_ban')::boolean then 'Bán lại mặt hàng' else 'Ngừng bán mặt hàng' end
                           else 'Sửa mặt hàng' end end;
    if op = 'DELETE' then muc := 3; end if;
    if d ? 'gia_von' then tom := tom || ' · giá vốn ' || coalesce(so_dep((o->>'gia_von')::numeric), '?') || ' → ' || coalesce(so_dep((n->>'gia_von')::numeric), '?'); end if;
    if d ? 'ten' and op = 'UPDATE' then tom := (o->>'ten') || ' → ' || tom; end if;
  when 'bang_gia' then
    loai := 'gia';
    select h.ten into ten from hang_hoa h where h.id = r->>'hang_hoa_id';
    tom := coalesce(ten, r->>'hang_hoa_id') || ' (' || (r->>'quy_cach') || ')';
    if op = 'INSERT' then viec := 'Thêm giá'; tom := tom || ': ' || so_dep((n->>'gia_ban')::numeric);
    elsif op = 'DELETE' then viec := 'Xoá giá'; muc := 3; tom := tom || ': ' || so_dep((o->>'gia_ban')::numeric);
    elsif d ? 'gia_ban' then viec := 'Đổi giá'; tom := tom || ': ' || so_dep((o->>'gia_ban')::numeric) || ' → ' || so_dep((n->>'gia_ban')::numeric);
      if (n->>'gia_ban')::numeric < (o->>'gia_ban')::numeric then muc := 3; end if;
    elsif d ? 'dang_ap_dung' then viec := case when (n->>'dang_ap_dung')::boolean then 'Dùng lại giá' else 'Bỏ giá' end;
      tom := tom || ': ' || so_dep((r->>'gia_ban')::numeric);
    elsif d ? 'cho_duyet' and d - 'cho_duyet' = '{}'::jsonb then
      viec := case when (n->>'cho_duyet')::boolean then 'Giá chờ duyệt' else 'Duyệt giá' end; tom := tom || ': ' || so_dep((r->>'gia_ban')::numeric);
    else viec := 'Sửa giá'; tom := tom || ': ' || so_dep((r->>'gia_ban')::numeric); end if;
  when 'khach_hang' then
    loai := 'khach'; tom := (r->>'ten') || coalesce(' – ' || nullif(r->>'sdt', ''), '');
    viec := case op when 'INSERT' then 'Thêm khách' when 'DELETE' then 'Xoá khách'
                 else case when d ? 'han_muc_no' then 'Đổi hạn mức nợ' when d ? 'khoa' then 'Khoá / mở khách' else 'Sửa khách' end end;
    if op = 'DELETE' or d ? 'han_muc_no' then muc := 3; end if;
    if d ? 'han_muc_no' then tom := tom || ' · hạn mức ' || coalesce(so_dep((o->>'han_muc_no')::numeric), 'không') || ' → ' || coalesce(so_dep((n->>'han_muc_no')::numeric), 'không'); end if;
  when 'nha_cung_cap' then
    loai := 'ncc'; tom := r->>'ten';
    viec := case op when 'INSERT' then 'Thêm NCC' when 'DELETE' then 'Xoá NCC'
                 else case when d ?| array['bin', 'ten_ngan_hang', 'so_tk', 'ten_tk', 'anh_qr'] then '⚠ Đổi tài khoản NCC'
                           when d ? 'dang_hop_tac' then case when (n->>'dang_hop_tac')::boolean then 'Hợp tác lại NCC' else 'Ngừng hợp tác NCC' end
                           else 'Sửa NCC' end end;
    if op = 'DELETE' or viec like '⚠%' then muc := 3; end if;
    if viec like '⚠%' then tom := tom || ' · TK ' || coalesce(o->>'so_tk', 'trống') || ' → ' || coalesce(n->>'so_tk', 'trống'); end if;
  when 'don_hang' then
    loai := 'don'; select k.ten into kh from khach_hang k where k.id = r->>'khach_hang_id';
    tom := (r->>'id') || ' · ' || coalesce(kh, '?') || ' · ' || so_dep((r->>'tong_cong')::numeric); tien := (r->>'tong_cong')::bigint;
    muc := 3;
    if op = 'DELETE' then viec := 'Xoá đơn';
    elsif d ? 'trang_thai' and n->>'trang_thai' = 'huy' then viec := 'Huỷ đơn';
      tom := tom || ' · huỷ sau ' || greatest(round(extract(epoch from now() - (r->>'ngay')::timestamptz) / 60), 0) || ' phút'
                 || coalesce(' · lý do: ' || nullif(n->>'ly_do_huy', ''), '');
    else viec := 'Sửa đơn'; end if;
  when 'don_hang_ct' then
    loai := 'don'; viec := 'Sửa đơn'; muc := 3;
    tom := (r->>'don_hang_id') || ': ' || (r->>'ten_hang') || ' (' || (r->>'quy_cach') || ') '
        || case op when 'INSERT' then 'thêm ' || so_dep((n->>'so_luong')::numeric)
                   when 'DELETE' then 'bỏ ' || so_dep((o->>'so_luong')::numeric)
                   else case when d ? 'so_luong' then 'SL ' || so_dep((o->>'so_luong')::numeric) || ' → ' || so_dep((n->>'so_luong')::numeric) || ' ' else '' end
                     || case when d ? 'don_gia' then 'giá ' || so_dep((o->>'don_gia')::numeric) || ' → ' || so_dep((n->>'don_gia')::numeric) else '' end end;
  when 'thanh_toan' then
    loai := 'tien'; select k.ten into kh from khach_hang k where k.id = r->>'khach_hang_id';
    tien := (r->>'so_tien')::bigint;
    tom := coalesce(kh, '?') || ' · ' || so_dep((r->>'so_tien')::numeric) || ' (' || (r->>'hinh_thuc') || ')' || coalesce(' · đơn ' || (r->>'don_hang_id'), '');
    viec := case op when 'INSERT' then 'Thu nợ' when 'DELETE' then 'Huỷ khoản thu' else 'Sửa khoản thu' end;
    if op <> 'INSERT' then muc := 3; end if;
  when 'phieu_nhap' then
    loai := 'kho'; muc := 3; tien := (r->>'tong_tien')::bigint;
    select c.ten into ten from nha_cung_cap c where c.id = r->>'ncc_id';
    tom := (r->>'id') || ' · ' || coalesce(ten, '?') || ' · ' || so_dep((r->>'tong_tien')::numeric);
    viec := case when op = 'DELETE' then 'Xoá phiếu nhập' when d ? 'trang_thai' and n->>'trang_thai' = 'huy' then 'Huỷ phiếu nhập' else 'Sửa phiếu nhập' end;
  when 'phieu_nhap_ct' then
    loai := 'kho'; viec := 'Sửa phiếu nhập'; muc := 3;
    tom := (r->>'phieu_nhap_id') || ': ' || (r->>'ten_hang') || ' ' || so_dep((r->>'so_luong')::numeric) || ' × ' || so_dep((r->>'don_gia_nhap')::numeric);
  when 'tra_ncc' then
    loai := 'tien'; tien := (r->>'so_tien')::bigint;
    select c.ten into ten from nha_cung_cap c where c.id = r->>'ncc_id';
    tom := coalesce(ten, '?') || ' · ' || so_dep((r->>'so_tien')::numeric) || coalesce(' (' || (r->>'hinh_thuc') || ')', '');
    viec := case op when 'INSERT' then 'Trả tiền NCC' when 'DELETE' then 'Huỷ trả NCC' else 'Sửa trả NCC' end;
    if op <> 'INSERT' then muc := 3; end if;
  when 'tra_hang' then
    loai := 'kho'; tien := (r->>'thanh_tien')::bigint;
    tom := (r->>'ten_hang') || ' ' || so_dep((r->>'so_luong')::numeric) || ' ' || (r->>'quy_cach') || coalesce(' · đơn ' || (r->>'don_hang_id'), '');
    viec := case op when 'INSERT' then 'Trả hàng' when 'DELETE' then 'Xoá trả hàng'
                 else 'Trả hàng: ' || coalesce(o->>'trang_thai', '') || ' → ' || coalesce(n->>'trang_thai', '') end;
    muc := case when op = 'UPDATE' then 1 else 2 end;
  when 'kiem_kho' then
    loai := 'kho'; viec := 'Kiểm kho';
    select h.ten into ten from hang_hoa h where h.id = r->>'hang_hoa_id';
    tom := coalesce(ten, '?') || ': ' || coalesce(so_dep((r->>'ton_cu')::numeric), '?') || ' → ' || coalesce(so_dep((r->>'ton_moi')::numeric), '?');
  when 'nhan_vien' then
    loai := 'he_thong'; tom := r->>'ten'; muc := 3;
    if op = 'INSERT' then viec := 'Thêm nhân viên';
    elsif op = 'DELETE' then viec := 'Xoá nhân viên';
    elsif d ? 'quyen' then viec := 'Đổi quyền';
      select tom || coalesce(' · BẬT: ' || string_agg(_ten_quyen(k), ', ') filter (where b), '')
                 || coalesce(' · TẮT: ' || string_agg(_ten_quyen(k), ', ') filter (where not b), '')
        into tom
        from (select k, coalesce((n->'quyen'->>k)::boolean, false) b
                from (select jsonb_object_keys(coalesce(o->'quyen', '{}') || coalesce(n->'quyen', '{}')) k) x
               where coalesce((o->'quyen'->>k)::boolean, false) <> coalesce((n->'quyen'->>k)::boolean, false)) y;
    elsif d ? 'hoat_dong' then viec := case when (n->>'hoat_dong')::boolean then 'Mở khoá nhân viên' else 'Khoá nhân viên' end;
    else viec := 'Sửa nhân viên'; end if;
  when 'chot_so' then
    loai := 'he_thong'; viec := 'Chốt sổ'; tien := (r->>'lech')::bigint;
    tom := (r->>'ngay') || ' · lệch ' || coalesce(so_dep((r->>'lech')::numeric), '0');
  when 'cau_hinh' then
    loai := 'he_thong'; muc := 3;
    viec := case when r->>'khoa' = 'ngan_hang' then '⚠ Đổi tài khoản cửa hàng' else 'Sửa thông tin cửa hàng' end;
    tom := case when r->>'khoa' = 'ngan_hang' then coalesce(o#>>'{gia_tri,so_tk}', 'trống') || ' → ' || coalesce(n#>>'{gia_tri,so_tk}', 'trống') else r->>'khoa' end;
  when 'yeu_cau_duyet' then
    loai := 'he_thong'; tien := (r->>'tong_cong')::bigint;
    tom := coalesce(r->>'nguoi_gui', '?') || ' · ' || coalesce(r->>'khach', '') || ' · ' || coalesce(so_dep((r->>'tong_cong')::numeric), '');
    viec := case when op = 'INSERT' then 'Xin chủ duyệt'
                 when n->>'trang_thai' = 'dong_y' then 'Chủ đồng ý yêu cầu'
                 when n->>'trang_thai' = 'tu_choi' then 'Chủ từ chối yêu cầu'
                 else 'Yêu cầu duyệt: ' || coalesce(n->>'trang_thai', '') end;
  when 'ma_vach' then
    loai := 'hang'; muc := 1;
    select h.ten into ten from hang_hoa h where h.id = r->>'hang_hoa_id';
    viec := case op when 'DELETE' then 'Bỏ mã vạch' else 'Gắn mã vạch' end; tom := coalesce(ten, '?') || ' · ' || (r->>'ma');
  when 'chuong_trinh_thuong' then
    loai := 'he_thong'; viec := case op when 'INSERT' then 'Thêm chương trình thưởng' when 'DELETE' then 'Xoá chương trình thưởng' else 'Sửa chương trình thưởng' end;
    tom := r->>'ten';
  else loai := 'he_thong'; viec := op || ' ' || t; tom := r->>'id';
  end case;
end $$;
revoke execute on function _nk_mo_ta(text, text, jsonb, jsonb, jsonb) from public, anon, authenticated;
update nhan_vien set quyen = quyen - 'sua_hang' where quyen ? 'sua_hang';
commit;
notify pgrst, 'reload schema';
