-- ═══════════════════════════════════════════════════════════════════
-- NV01 – NHẬT KÝ THAY ĐỔI (anh Tâm duyệt 14/11/2026)
-- • Máy chủ tự ghi (trigger) mọi thêm / sửa / xoá của NHÂN VIÊN, CHỦ và SỬA TRỰC TIẾP MÁY CHỦ (SQL Editor)
--   trên: hàng, giá, khách, NCC, đơn đã lưu (huỷ / sửa / xoá), thu nợ, trả NCC, nhập toa, kiểm kho,
--   quyền nhân viên, thông tin cửa hàng, chốt sổ, yêu cầu duyệt, mã vạch, chương trình thưởng.
-- • Đơn bán BÌNH THƯỜNG không ghi. Đơn "bất thường" (chiết khấu, bán khác giá bảng / giảm giá dòng, trả hàng,
--   vượt hạn mức nợ, có chủ duyệt) và "⚠ SỬA ĐƠN" (huỷ rồi lên lại cho cùng khách trong 30 phút) thì ghi.
-- • 1 thao tác = 1 giao dịch (cột tx) → app gộp thành 1 dòng. Cùng 1 dòng dữ liệu đổi nhiều lần trong 1 giao dịch
--   → gộp thành 1 thay đổi thực (cũ → mới), đổi đi đổi lại về như cũ thì không ghi.
-- • Chỉ CHỦ đọc được. Không ai thêm / sửa / xoá được qua app hay API. Tự xoá dòng cũ hơn 1 năm.
-- Quay lại: nv01_quay_lai.sql
-- ═══════════════════════════════════════════════════════════════════
begin;

create table if not exists nhat_ky (
  id        bigserial primary key,
  luc       timestamptz not null default now(),
  tx        bigint not null default txid_current(),
  nguoi_id  uuid,
  nguoi     text not null,
  vai       text not null check (vai in ('chu', 'nv', 'may_chu')),
  bang      text not null,
  hanh_dong text not null,          -- INSERT / UPDATE / DELETE / DON (đơn bất thường, sửa đơn) / PHIEU (nhập toa)
  doi_tuong text,                   -- mã dòng dữ liệu
  loai      text not null,          -- hang, gia, khach, ncc, don, tien, kho, he_thong
  viec      text not null,          -- "Đổi giá", "Huỷ đơn"…
  muc       int not null default 2, -- 3 = cần để ý, 2 = thường, 1 = phụ
  tom_tat   text,
  so_tien   bigint,
  cu        jsonb,
  moi       jsonb,
  them      jsonb
);
create index if not exists nhat_ky_luc on nhat_ky (luc desc);
create index if not exists nhat_ky_tx on nhat_ky (tx, bang, doi_tuong);
alter table nhat_ky enable row level security;
drop policy if exists nhat_ky_chu_doc on nhat_ky;
create policy nhat_ky_chu_doc on nhat_ky for select to authenticated using (la_chu());
revoke all on nhat_ky from public, anon, authenticated;
grant select on nhat_ky to authenticated;
revoke all on sequence nhat_ky_id_seq from public, anon, authenticated;

-- ── Sổ tạm trong 1 giao dịch: đơn / phiếu nhập vừa tạo (để bỏ qua các dòng con của chúng) ──
create or replace function _nk_dk(k text) returns void language sql as $$
  select set_config('nk.moi', coalesce(current_setting('nk.moi', true), '') || '|' || k || '|', true) $$;
create or replace function _nk_co(k text) returns boolean language sql stable as $$
  select position('|' || k || '|' in coalesce(current_setting('nk.moi', true), '')) > 0 $$;
create or replace function _nk_co_bang(t text) returns boolean language sql stable as $$
  select position('|' || t || ':' in coalesce(current_setting('nk.moi', true), '')) > 0 $$;

-- ── Ai đang làm ──
create or replace function _nk_nguoi(out vai text, out ten text, out uid uuid)
language plpgsql stable security definer set search_path = public as $$
begin
  uid := auth.uid();
  if uid is null then vai := 'may_chu'; ten := '🔧 Sửa trực tiếp máy chủ';
  elsif la_chu() then vai := 'chu'; ten := coalesce(_ten_nguoi_dung(), 'Chủ');
  else vai := 'nv'; ten := coalesce(_ten_nguoi_dung(), '?'); end if;
end $$;

-- ── Các cột "thay đổi" thật (bỏ cột tự cập nhật) ──
create or replace function _nk_khac(o jsonb, n jsonb, bo text[]) returns jsonb language sql immutable as $$
  select coalesce(jsonb_object_agg(k, jsonb_build_array(o->k, n->k)), '{}'::jsonb)
    from (select jsonb_object_keys(coalesce(n, o)) k) x
   where not (k = any (bo)) and (o->k) is distinct from (n->k) $$;

create or replace function _nk_bo_cot(t text) returns text[] language sql stable as $$
  select array['sua_luc', 'tao_luc', 'ton_kho', 'nhac_no_luc', 'da_giao', 'giao_luc', 'nguoi_giao']
    || case t when 'yeu_cau_duyet' then array['da_dung', 'don_hang_id'] else '{}'::text[] end
    -- giá vốn tự cập nhật khi nhập toa: không tính là "sửa mặt hàng"
    || case when t = 'hang_hoa' and _nk_co_bang('phieu_nhap') then array['gia_von'] else '{}'::text[] end $$;

-- ── Mô tả 1 thay đổi thành câu dễ đọc ──
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

-- ── Ghi 1 dòng nhật ký ──
create or replace function _nk_ghi(p_bang text, p_hd text, p_dt text, p_loai text, p_viec text, p_muc int, p_tom text,
                                   p_tien bigint, p_cu jsonb, p_moi jsonb, p_them jsonb) returns bigint
language plpgsql security definer set search_path = public as $$
declare ng record; v_id bigint;
begin
  ng := _nk_nguoi();
  insert into nhat_ky (nguoi_id, nguoi, vai, bang, hanh_dong, doi_tuong, loai, viec, muc, tom_tat, so_tien, cu, moi, them)
  values (ng.uid, ng.ten, ng.vai, p_bang, p_hd, p_dt, p_loai, p_viec, p_muc, p_tom, p_tien, p_cu, p_moi, p_them)
  returning id into v_id;
  if random() < 0.02 then delete from nhat_ky where luc < now() - interval '1 year'; end if;   -- giữ 1 năm
  return v_id;
end $$;

-- ── Trigger chung cho từng dòng ──
create or replace function _nk_dong() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  t text := tg_table_name; op text := tg_op;
  o jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  n jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  r jsonb; k text; e record; v_op text; v_cu jsonb; d jsonb; m record;
begin
  r := coalesce(n, o);
  k := coalesce(r->>'id', r->>'khoa', r->>'ngay', r->>'ma');
  -- Đơn / phiếu nhập: lúc tạo do trigger cuối giao dịch ghi (chỉ khi bất thường). Ở đây chỉ đánh dấu "mới tạo".
  if t in ('don_hang', 'phieu_nhap') then
    if op = 'INSERT' then perform _nk_dk(t || ':' || k); return null; end if;
    if op = 'UPDATE' and _nk_co(t || ':' || k) then return null; end if;
  end if;
  -- Dòng con của đơn / phiếu vừa tạo trong cùng giao dịch → là 1 phần việc tạo, bỏ qua
  if t in ('don_hang_ct', 'thanh_toan', 'tra_hang') and _nk_co('don_hang:' || coalesce(r->>'don_hang_id', '')) then return null; end if;
  if t = 'phieu_nhap_ct' and _nk_co('phieu_nhap:' || coalesce(r->>'phieu_nhap_id', '')) then return null; end if;
  if t = 'thanh_toan' and r->>'tu_don' is not null then return null; end if;   -- cấn trừ tự động theo đơn

  -- Gộp mọi thay đổi của CÙNG 1 dòng trong CÙNG 1 giao dịch thành 1 thay đổi thực
  select id, hanh_dong, cu into e from nhat_ky where tx = txid_current() and bang = t and doi_tuong = k
     and hanh_dong in ('INSERT', 'UPDATE', 'DELETE') order by id desc limit 1;
  if found then
    if op = 'DELETE' and e.hanh_dong = 'INSERT' then delete from nhat_ky where id = e.id; return null; end if;
    v_op := case when e.hanh_dong = 'INSERT' then 'INSERT' else op end; v_cu := e.cu;
  else v_op := op; v_cu := o; end if;
  d := case when v_op = 'UPDATE' then _nk_khac(v_cu, n, _nk_bo_cot(t)) else '{}'::jsonb end;
  if v_op = 'UPDATE' and d = '{}'::jsonb then
    if e.id is not null then delete from nhat_ky where id = e.id; end if;
    return null;
  end if;
  m := _nk_mo_ta(t, v_op, v_cu, n, d);
  if e.id is not null then
    update nhat_ky set hanh_dong = v_op, moi = n, loai = m.loai, viec = m.viec, muc = m.muc, tom_tat = m.tom, so_tien = m.tien where id = e.id;
  else
    perform _nk_ghi(t, v_op, k, m.loai, m.viec, m.muc, m.tom, m.tien, v_cu, n, null);
  end if;
  return null;
end $$;

-- ── Cuối giao dịch: đơn mới có bất thường / là "sửa đơn" thì ghi ──
create or replace function _nk_don_moi() returns trigger
language plpgsql security definer set search_path = public as $$
declare d don_hang%rowtype; kh khach_hang%rowtype; ly text[] := '{}'; v text; v_no bigint; h record; v_doi text; v_tom text;
begin
  select * into d from don_hang where id = new.id;
  if not found or d.trang_thai = 'huy' then return null; end if;
  select * into kh from khach_hang where id = d.khach_hang_id;
  if d.chiet_khau > 0 then ly := ly || ('chiết khấu ' || so_dep(d.chiet_khau)); end if;
  select string_agg(c.ten_hang || ' ' || so_dep(c.don_gia - c.giam_gia) || ' (bảng ' || coalesce(so_dep(b.gia_ban), '–') || ')', ', ') into v
    from don_hang_ct c left join bang_gia b on b.hang_hoa_id = c.hang_hoa_id and lower(b.quy_cach) = lower(c.quy_cach) and b.dang_ap_dung
   where c.don_hang_id = d.id and (c.giam_gia > 0 or (b.id is not null and c.don_gia <> b.gia_ban));
  if v is not null then ly := ly || ('bán khác giá: ' || v); end if;
  select string_agg(ten_hang || ' ' || so_dep(so_luong) || ' ' || quy_cach, ', ') into v from tra_hang where don_hang_id = d.id;
  if v is not null then ly := ly || ('trả hàng: ' || v); end if;
  if d.hinh_thuc = 'Ghi nợ' and coalesce(kh.han_muc_no, 0) > 0 then
    select coalesce(sum(con_no), 0) into v_no from v_don_hang where khach_hang_id = d.khach_hang_id;
    if v_no > kh.han_muc_no then ly := ly || ('vượt hạn mức nợ: nợ ' || so_dep(v_no) || ' / hạn mức ' || so_dep(kh.han_muc_no)); end if;
  end if;
  if exists (select 1 from yeu_cau_duyet where don_hang_id = d.id) then ly := ly || 'có chủ duyệt'::text; end if;

  -- SỬA ĐƠN: vừa huỷ 1 đơn của cùng khách trong 30 phút (khách lẻ: cùng người làm)
  select id, doi_tuong, so_tien into h from nhat_ky
   where bang = 'don_hang' and viec = 'Huỷ đơn' and luc > now() - interval '30 minutes' and them is null
     and moi->>'khach_hang_id' = d.khach_hang_id and (d.khach_hang_id <> 'KHLE' or nguoi_id is not distinct from auth.uid())
   order by id desc limit 1;
  if found then
    with a as (select ten_hang, quy_cach, sum(so_luong) sl, max(don_gia - giam_gia) g from don_hang_ct where don_hang_id = h.doi_tuong group by 1, 2),
         b as (select ten_hang, quy_cach, sum(so_luong) sl, max(don_gia - giam_gia) g from don_hang_ct where don_hang_id = d.id group by 1, 2)
    select string_agg(case when a.sl is null then 'thêm ' || so_dep(b.sl) || ' ' || quy_cach || ' ' || ten_hang
                           when b.sl is null then 'bỏ ' || so_dep(a.sl) || ' ' || quy_cach || ' ' || ten_hang
                           else ten_hang || ': ' || concat_ws(', ',
                                  case when a.sl <> b.sl then so_dep(a.sl) || ' → ' || so_dep(b.sl) || ' ' || quy_cach end,
                                  case when a.g <> b.g then 'giá ' || so_dep(a.g) || ' → ' || so_dep(b.g) end) end, '; ' order by ten_hang)
      into v_doi
      from a full join b using (ten_hang, quy_cach)
     where a.sl is null or b.sl is null or a.sl <> b.sl or a.g <> b.g;
    v_tom := h.doi_tuong || ' → ' || d.id || ' · ' || coalesce(kh.ten, '?') || ' · ' || so_dep(coalesce(h.so_tien, 0)) || ' → ' || so_dep(d.tong_cong)
          || ' · ' || coalesce(v_doi, 'hàng giữ nguyên') || case when cardinality(ly) > 0 then ' · ' || array_to_string(ly, ' · ') else '' end;
    perform _nk_ghi('don_hang', 'DON', d.id, 'don', '⚠ Sửa đơn', 3, v_tom, d.tong_cong, null,
                    jsonb_build_object('don_cu', h.doi_tuong, 'don_moi', d.id, 'khach_hang_id', d.khach_hang_id), jsonb_build_object('ly_do', ly));
    update nhat_ky set them = jsonb_build_object('sua_thanh', d.id) where id = h.id;
  elsif cardinality(ly) > 0 then
    perform _nk_ghi('don_hang', 'DON', d.id, 'don', 'Đơn bất thường',
                    case when d.chiet_khau > 0 or exists (select 1 from unnest(ly) x where x like 'bán khác giá%' or x like 'vượt%') then 3 else 2 end,
                    d.id || ' · ' || coalesce(kh.ten, '?') || ' · ' || so_dep(d.tong_cong) || ' · ' || array_to_string(ly, ' · '),
                    d.tong_cong, null, jsonb_build_object('khach_hang_id', d.khach_hang_id, 'hinh_thuc', d.hinh_thuc), jsonb_build_object('ly_do', ly));
  end if;
  return null;
end $$;

-- ── Cuối giao dịch: phiếu nhập (nhập toa) mới ──
create or replace function _nk_phieu_moi() returns trigger
language plpgsql security definer set search_path = public as $$
declare p phieu_nhap%rowtype; v_ncc text; v_n int;
begin
  select * into p from phieu_nhap where id = new.id;
  if not found then return null; end if;
  select ten into v_ncc from nha_cung_cap where id = p.ncc_id;
  select count(*) into v_n from phieu_nhap_ct where phieu_nhap_id = p.id;
  perform _nk_ghi('phieu_nhap', 'PHIEU', p.id, 'kho', 'Nhập toa', 2,
                  p.id || ' · ' || coalesce(v_ncc, '?') || coalesce(' · toa ' || nullif(p.so_toa, ''), '') || ' · ' || v_n || ' món · ' || so_dep(coalesce(p.tong_tien, 0)),
                  p.tong_tien, null, to_jsonb(p), null);
  return null;
end $$;

-- ── Gắn trigger ──
do $$ declare t text; begin
  foreach t in array array['hang_hoa', 'bang_gia', 'khach_hang', 'nha_cung_cap', 'don_hang', 'don_hang_ct', 'thanh_toan',
                           'phieu_nhap', 'phieu_nhap_ct', 'tra_ncc', 'tra_hang', 'kiem_kho', 'nhan_vien', 'chot_so', 'cau_hinh',
                           'yeu_cau_duyet', 'ma_vach', 'chuong_trinh_thuong'] loop
    execute format('drop trigger if exists trg_nhat_ky on %I', t);
    execute format('create trigger trg_nhat_ky after insert or update or delete on %I for each row execute function _nk_dong()', t);
  end loop;
end $$;
drop trigger if exists trg_nhat_ky_don_moi on don_hang;
create constraint trigger trg_nhat_ky_don_moi after insert on don_hang deferrable initially deferred for each row execute function _nk_don_moi();
drop trigger if exists trg_nhat_ky_phieu_moi on phieu_nhap;
create constraint trigger trg_nhat_ky_phieu_moi after insert on phieu_nhap deferrable initially deferred for each row execute function _nk_phieu_moi();

-- Không ai gọi thẳng các hàm nội bộ được
revoke execute on function _nk_dk(text), _nk_co(text), _nk_co_bang(text), _nk_nguoi(), _nk_khac(jsonb, jsonb, text[]), _nk_bo_cot(text),
  _nk_mo_ta(text, text, jsonb, jsonb, jsonb), _nk_ghi(text, text, text, text, text, int, text, bigint, jsonb, jsonb, jsonb),
  _nk_dong(), _nk_don_moi(), _nk_phieu_moi() from public, anon, authenticated;

commit;
notify pgrst, 'reload schema';
