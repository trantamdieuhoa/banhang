-- PQ01 QUAY LẠI: trả các hàm về bản trước PQ01, xoá quyền + yêu cầu duyệt.
begin;
CREATE OR REPLACE FUNCTION public.doi_gia_ban(p jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_it jsonb; v_g bigint; v_n int := 0; v_k int;
begin
  perform _bat_buoc_nhan_vien();
  for v_it in select * from jsonb_array_elements(coalesce(p, '[]'::jsonb)) loop
    v_g := _tien(v_it->>'gia_ban');
    if v_g is null or v_g <= 0 then raise exception 'Giá bán không hợp lệ'; end if;
    update bang_gia set gia_ban = v_g
     where hang_hoa_id = v_it->>'hang_hoa_id' and lower(quy_cach) = lower(v_it->>'quy_cach') and dang_ap_dung;
    get diagnostics v_k = row_count; v_n := v_n + v_k;
  end loop;
  return v_n;
end $function$;

CREATE OR REPLACE FUNCTION public.thu_tien(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_dh_id text := nullif(trim(p->>'don_hang_id'), '');
  v_kh    text := nullif(trim(p->>'khach_hang_id'), '');
  v_con   bigint := _tien(p->>'so_tien');
  v_ht    text := coalesce(nullif(p->>'hinh_thuc', ''), 'Tiền mặt');
  v_nv    text := _ten_nguoi_dung();
  v_anh   text[] := _ds_anh(p->'anh');
  v_kq    jsonb := '[]'::jsonb;
  v_tra   bigint;
  r       record;
begin
  perform _bat_buoc_nhan_vien();
  if v_con is null or v_con <= 0 then raise exception 'Số tiền không hợp lệ'; end if;
  if v_ht not in ('Tiền mặt', 'Chuyển khoản') then raise exception 'Hình thức không hợp lệ: %', v_ht; end if;
  if v_kh is null and v_dh_id is not null then
    select khach_hang_id into v_kh from don_hang where id = v_dh_id;
  end if;
  if v_kh is null then raise exception 'Thiếu khách hàng'; end if;

  perform 1 from don_hang where khach_hang_id = v_kh for update;

  for r in
    select id, con_no from v_don_hang
     where khach_hang_id = v_kh and con_no > 0 and (v_dh_id is null or id = v_dh_id)
     order by ngay, id
  loop
    exit when v_con <= 0;
    v_tra := least(v_con, r.con_no);
    insert into thanh_toan (khach_hang_id, don_hang_id, so_tien, hinh_thuc, ma_gd, nhan_vien_id, nguoi_thu, ghi_chu, anh)
    values (v_kh, r.id, v_tra, v_ht, nullif(trim(p->>'ma_gd'), ''), auth.uid(), v_nv, nullif(trim(p->>'ghi_chu'), ''), v_anh);
    v_con := v_con - v_tra;
    v_kq := v_kq || jsonb_build_object('don_hang_id', r.id, 'so_tien', v_tra);
  end loop;

  if jsonb_array_length(v_kq) = 0 then raise exception 'Không có đơn nào còn nợ'; end if;
  return jsonb_build_object('da_tru', v_kq, 'tien_thua', v_con);
end $function$;

CREATE OR REPLACE FUNCTION public.tra_no_ncc(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_tien bigint := _tien(p->>'so_tien'); v_ht text := coalesce(nullif(p->>'hinh_thuc', ''), 'Tiền mặt'); v_id bigint;
begin
  perform _bat_buoc_nhan_vien();
  if v_tien is null or v_tien <= 0 then raise exception 'Số tiền không hợp lệ'; end if;
  if v_ht not in ('Tiền mặt', 'Chuyển khoản') then raise exception 'Hình thức không hợp lệ: %', v_ht; end if;
  if not exists (select 1 from nha_cung_cap where id = p->>'ncc_id') then raise exception 'Không tìm thấy NCC'; end if;
  insert into tra_ncc (ncc_id, so_tien, hinh_thuc, nguoi_tra, ghi_chu, anh)
  values (p->>'ncc_id', v_tien, v_ht, _ten_nguoi_dung(), nullif(trim(p->>'ghi_chu'), ''), _ds_anh(p->'anh'))
  returning id into v_id;
  return jsonb_build_object('id', v_id);
end $function$;

CREATE OR REPLACE FUNCTION public.tao_toa_ncc(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_ncc  text := nullif(trim(p->>'ncc_id'), '');
  v_tien bigint := _tien(p->>'tong_tien');
  v_ngay timestamptz := case when nullif(p->>'ngay', '') is null then now()
                             when (p->>'ngay')::date = vn_ngay(now()) then now()
                             else ((p->>'ngay')::date + time '12:00') at time zone 'Asia/Ho_Chi_Minh' end;
  v_tra  bigint := coalesce(_tien(p#>>'{tra,so_tien}'), 0);
  v_id   text;
begin
  perform _bat_buoc_nhan_vien();
  if v_ncc is null or not exists (select 1 from nha_cung_cap where id = v_ncc) then raise exception 'Chưa chọn nhà cung cấp'; end if;
  if v_tien is null or v_tien <= 0 then raise exception 'Chưa nhập tổng tiền toa'; end if;
  if v_ngay > now() + interval '1 day' then raise exception 'Ngày toa ở tương lai'; end if;
  if v_tra < 0 or v_tra > v_tien then raise exception 'Số tiền trả phải từ 0 đến tổng tiền toa'; end if;

  insert into phieu_nhap (ncc_id, ngay, tong_tien, ghi_chu, so_toa, anh, nhan_vien_id, nguoi_nhap)
  values (v_ncc, v_ngay, v_tien, nullif(trim(p->>'ghi_chu'), ''), nullif(trim(p->>'so_toa'), ''),
          _ds_anh(p->'anh'), auth.uid(), _ten_nguoi_dung())
  returning id into v_id;

  if v_tra > 0 then
    insert into tra_ncc (ncc_id, phieu_nhap_id, so_tien, hinh_thuc, ngay, nguoi_tra, anh)
    values (v_ncc, v_id, v_tra, coalesce(nullif(p#>>'{tra,hinh_thuc}', ''), 'Tiền mặt'), v_ngay, _ten_nguoi_dung(), _ds_anh(p#>'{tra,anh}'));
  end if;
  return jsonb_build_object('id', v_id);
end $function$;

CREATE OR REPLACE FUNCTION public.nhap_hang(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_pn   text;
  v_ncc  text := nullif(trim(p->>'ncc_id'), '');
  v_nv   text := _ten_nguoi_dung();
  v_it   jsonb;
  v_hh   hang_hoa%rowtype;
  v_qc   text;
  v_qd   numeric;
  v_sl   numeric;
  v_gia  bigint;
  v_tt   bigint;
  v_tong bigint := 0;
  v_tra  bigint := coalesce(_tien(p->>'da_tra'), 0);
  v_cnv  boolean := coalesce((p->>'cap_nhat_gia_von')::boolean, true);
begin
  perform _bat_buoc_nhan_vien();
  if jsonb_typeof(p->'items') is distinct from 'array' or jsonb_array_length(p->'items') = 0 then
    raise exception 'Phiếu nhập chưa có mặt hàng nào';
  end if;
  if v_ncc is not null and not exists (select 1 from nha_cung_cap where id = v_ncc) then
    raise exception 'Không tìm thấy nhà cung cấp %', v_ncc;
  end if;

  insert into phieu_nhap (ncc_id, ghi_chu, nhan_vien_id, nguoi_nhap)
  values (v_ncc, nullif(trim(p->>'ghi_chu'), ''), auth.uid(), v_nv) returning id into v_pn;

  for v_it in select * from jsonb_array_elements(p->'items') loop
    select * into v_hh from hang_hoa where id = v_it->>'hang_hoa_id';
    if not found then raise exception 'Không tìm thấy mặt hàng %', v_it->>'hang_hoa_id'; end if;
    v_qc := coalesce(nullif(trim(v_it->>'quy_cach'), ''), v_hh.don_vi);
    v_qd := coalesce(nullif(trim(v_it->>'so_luong_quy_doi'), '')::numeric,
                     (select so_luong_quy_doi from bang_gia
                       where hang_hoa_id = v_hh.id and lower(quy_cach) = lower(v_qc) and dang_ap_dung limit 1),
                     1);
    v_sl := nullif(trim(v_it->>'so_luong'), '')::numeric;
    if v_sl is null or v_sl <= 0 then raise exception 'Số lượng không hợp lệ: %', v_hh.ten; end if;
    v_gia := coalesce(_tien(v_it->>'don_gia_nhap'), 0);
    v_tt  := round(v_sl * v_gia);

    insert into phieu_nhap_ct (phieu_nhap_id, hang_hoa_id, ten_hang, quy_cach, so_luong_quy_doi, so_luong, don_gia_nhap, thanh_tien)
    values (v_pn, v_hh.id, v_hh.ten, v_qc, v_qd, v_sl, v_gia, v_tt);
    v_tong := v_tong + v_tt;

    update hang_hoa set
      ton_kho = ton_kho + v_sl * v_qd,
      gia_von = case when v_cnv and v_gia > 0 then round(v_gia / v_qd) else gia_von end,
      ncc_id  = coalesce(ncc_id, v_ncc)
    where id = v_hh.id;
  end loop;

  update phieu_nhap set tong_tien = v_tong where id = v_pn;

  if v_tra > 0 then
    if v_ncc is null then raise exception 'Muốn ghi đã trả thì phải chọn nhà cung cấp'; end if;
    insert into tra_ncc (ncc_id, phieu_nhap_id, so_tien, hinh_thuc, nguoi_tra)
    values (v_ncc, v_pn, least(v_tra, v_tong), coalesce(nullif(p->>'hinh_thuc', ''), 'Tiền mặt'), v_nv);
  end if;

  return jsonb_build_object('id', v_pn, 'tong_tien', v_tong);
end $function$;

CREATE OR REPLACE FUNCTION public.luu_ct_toa(p_id text, p_items jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_pn   phieu_nhap%rowtype;
  v_it   jsonb;
  v_hh   hang_hoa%rowtype;
  v_qc   text;
  v_qd   numeric;
  v_sl   numeric;
  v_gia  bigint;
  v_gv   bigint;
  v_tong bigint := 0;
  v_n    int := 0;
  v_ton  int := 0;
  v_tang jsonb := '[]'::jsonb;
begin
  perform _bat_buoc_nhan_vien();
  select * into v_pn from phieu_nhap where id = p_id for update;
  if not found or v_pn.trang_thai <> 'hoan_tat' then raise exception 'Không tìm thấy toa % (hoặc đã huỷ)', p_id; end if;
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'Chi tiết toa không hợp lệ'; end if;

  perform _go_ct_toa(p_id);
  delete from phieu_nhap_ct where phieu_nhap_id = p_id;

  for v_it in select * from jsonb_array_elements(p_items) loop
    select * into v_hh from hang_hoa where id = v_it->>'hang_hoa_id' for update;
    if not found then raise exception 'Không tìm thấy mặt hàng %', v_it->>'hang_hoa_id'; end if;
    v_qc := coalesce(nullif(trim(v_it->>'quy_cach'), ''), v_hh.don_vi);
    v_qd := coalesce(nullif(trim(v_it->>'so_luong_quy_doi'), '')::numeric, 1);
    if v_qd <= 0 then v_qd := 1; end if;
    v_sl := nullif(trim(v_it->>'so_luong'), '')::numeric;
    if v_sl is null or v_sl <= 0 then raise exception 'Số lượng không hợp lệ: %', v_hh.ten; end if;
    v_gia := coalesce(_tien(v_it->>'don_gia_nhap'), 0);
    if v_gia < 0 then raise exception 'Đơn giá không hợp lệ: %', v_hh.ten; end if;
    v_gv := case when v_gia > 0 then round(v_gia / v_qd) end;

    insert into phieu_nhap_ct (phieu_nhap_id, hang_hoa_id, ten_hang, quy_cach, so_luong_quy_doi, so_luong,
                               don_gia_nhap, thanh_tien, cong_ton, gia_von_cu)
    values (p_id, v_hh.id, v_hh.ten, v_qc, v_qd, v_sl, v_gia, round(v_sl * v_gia), v_hh.ton_kho is not null, v_hh.gia_von);
    v_tong := v_tong + round(v_sl * v_gia);
    v_n := v_n + 1;
    if v_hh.ton_kho is not null then v_ton := v_ton + 1; end if;

    -- Giá vốn TĂNG (đã có giá vốn cũ) → báo cho app gợi ý giá bán mới. Món lặp 2 dòng trên toa chỉ báo 1 lần.
    if v_gv is not null and v_hh.gia_von > 0 and v_gv > v_hh.gia_von
       and not exists (select 1 from jsonb_array_elements(v_tang) x where x->>'id' = v_hh.id) then
      v_tang := v_tang || jsonb_build_object('id', v_hh.id, 'ten', v_hh.ten, 'dv', v_hh.don_vi,
        'gv_cu', v_hh.gia_von, 'gv_moi', v_gv,
        'gia', coalesce((select jsonb_agg(jsonb_build_object('qc', quy_cach, 'qd', so_luong_quy_doi, 'g', gia_ban)
                                          order by so_luong_quy_doi)
                         from bang_gia where hang_hoa_id = v_hh.id and dang_ap_dung), '[]'::jsonb));
    end if;

    update hang_hoa set
      ton_kho = ton_kho + v_sl * v_qd,                       -- NULL (không theo dõi) giữ nguyên NULL
      gia_von = coalesce(v_gv, gia_von)
    where id = v_hh.id;
    -- Toa của NCC nào → món đó do NCC đó bỏ (tự điền danh sách "mặt hàng NCC bỏ")
    if v_pn.ncc_id is not null then
      insert into ncc_hang (ncc_id, hang_hoa_id) values (v_pn.ncc_id, v_hh.id) on conflict do nothing;
    end if;
  end loop;

  return jsonb_build_object('so_dong', v_n, 'tong_ct', v_tong, 'cong_ton', v_ton, 'tang', v_tang);
end $function$;

CREATE OR REPLACE FUNCTION public.kiem_kho_cap_nhat(p jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_it jsonb; v_cu numeric; v_moi numeric; v_n int := 0;
begin
  perform _bat_buoc_nhan_vien();
  for v_it in select * from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) loop
    select ton_kho into v_cu from hang_hoa where id = v_it->>'hang_hoa_id' for update;
    if not found then raise exception 'Không tìm thấy mặt hàng %', v_it->>'hang_hoa_id'; end if;
    v_moi := nullif(trim(v_it->>'ton_kho'), '')::numeric;
    update hang_hoa set
      ton_kho = v_moi,
      ton_toi_thieu = case when v_it ? 'ton_toi_thieu' then nullif(trim(v_it->>'ton_toi_thieu'), '')::numeric else ton_toi_thieu end
    where id = v_it->>'hang_hoa_id';
    insert into kiem_kho (hang_hoa_id, ton_cu, ton_moi, nguoi) values (v_it->>'hang_hoa_id', v_cu, v_moi, _ten_nguoi_dung());
    v_n := v_n + 1;
  end loop;
  return v_n;
end $function$;

CREATE OR REPLACE FUNCTION public.dat_theo_doi_ton(p_ids text[], p_bat boolean)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_n int;
begin
  perform _bat_buoc_nhan_vien();
  if p_bat then
    update hang_hoa set ton_kho = 0 where id = any(p_ids) and ton_kho is null;
  else
    update hang_hoa set ton_kho = null, ton_toi_thieu = null where id = any(p_ids) and ton_kho is not null;
  end if;
  get diagnostics v_n = row_count;
  return v_n;
end $function$;

CREATE OR REPLACE FUNCTION public.huy_don_hang(p_id text, p_ly_do text DEFAULT NULL::text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_dh don_hang%rowtype;
begin
  perform _bat_buoc_nhan_vien();
  select * into v_dh from don_hang where id = p_id for update;
  if not found then raise exception 'Không tìm thấy đơn %', p_id; end if;
  if v_dh.trang_thai = 'huy' then raise exception 'Đơn đã huỷ rồi'; end if;
  if not la_chu() and not (v_dh.nhan_vien_id = auth.uid() and v_dh.ngay > now() - interval '30 minutes') then
    raise exception 'Nhân viên chỉ huỷ được đơn của mình trong 30 phút sau khi tạo';
  end if;
  if exists (select 1 from thanh_toan where don_hang_id = p_id) then
    raise exception 'Đơn đã có thanh toán. Hãy huỷ các khoản thanh toán trước';
  end if;
  if exists (select 1 from doi_thuong where don_hang_id = p_id and doi_nap_id is not null) then
    raise exception 'Nắp của đơn này đã mang đổi với NCC – không huỷ được';
  end if;
  if exists (select 1 from viec_treo_khach where don_hang_id = p_id and trang_thai = 'xong') then
    raise exception 'Đơn có khoản treo đã xử lý xong – chủ kiểm tra trước khi huỷ';
  end if;

  -- hàng bán → cộng lại tồn
  update hang_hoa h set ton_kho = h.ton_kho + c.sl
  from (select hang_hoa_id, sum(so_luong * so_luong_quy_doi) sl from don_hang_ct where don_hang_id = p_id group by 1) c
  where h.id = c.hang_hoa_id and h.ton_kho is not null;
  -- hàng khách trả (đã cộng tồn) → trừ lại
  update hang_hoa h set ton_kho = h.ton_kho - c.sl
  from (select hang_hoa_id, sum(so_luong * so_luong_quy_doi) sl from tra_hang
         where don_hang_id = p_id and hang_tot and trang_thai in ('da_tru', 'doi_lay_lai') group by 1) c
  where h.id = c.hang_hoa_id and h.ton_kho is not null;
  -- lon thưởng đã đưa khách → cộng lại
  update hang_hoa h set ton_kho = h.ton_kho + c.sl
  from (select hang_hoa_id, sum(so_nap * so_luong_hang) sl from doi_thuong
         where don_hang_id = p_id and loai = 'hang' and da_tra_khach group by 1) c
  where h.id = c.hang_hoa_id and h.ton_kho is not null;
  update tra_hang set trang_thai = 'huy' where don_hang_id = p_id;
  update doi_thuong set trang_thai = 'huy' where don_hang_id = p_id;
  update viec_treo_khach set trang_thai = 'huy', ket_qua = 'Huỷ đơn ' || p_id where don_hang_id = p_id and trang_thai = 'mo';
  -- khoản treo đã trừ vào đơn này → mở lại
  update viec_treo_khach set trang_thai = 'mo', ket_qua = null, xu_ly_luc = null, nguoi_xu_ly = null
   where trang_thai = 'xong' and ket_qua = 'Trừ vào đơn ' || p_id;
  delete from thanh_toan where tu_don = p_id;   -- gỡ cấn trừ vào nợ cũ
  update don_hang set trang_thai = 'huy', ly_do_huy = p_ly_do where id = p_id;
end $function$;

CREATE OR REPLACE FUNCTION public.bao_cao(p_tu date, p_den date)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v jsonb;
begin
  perform _bat_buoc_chu();
  with dh as (
    select *, coalesce(dt_thuan, tong_cong) as dt from don_hang where trang_thai = 'hoan_tat' and vn_ngay(ngay) between p_tu and p_den
  ), ct as (
    select c.*, vn_ngay(d.ngay) as ngay_ban, d.khach_hang_id
    from don_hang_ct c join dh d on d.id = c.don_hang_id
  ), von as (
    select don_hang_id,
           sum(so_luong * so_luong_quy_doi * gia_von) as gia_von,
           sum(thanh_tien) filter (where gia_von > 0) as dt_co_von
    from ct group by 1
  ), th as (   -- hàng trả còn tốt nhập lại kho → giảm giá vốn; trả sau (chủ nhận) → giảm doanh thu ngày nhận
    select t.*, coalesce(h.gia_von, 0) as gv_hh from tra_hang t join hang_hoa h on h.id = t.hang_hoa_id
     where (t.trang_thai = 'da_tru' and vn_ngay(t.ngay) between p_tu and p_den)
        or (t.trang_thai = 'da_nhan_sau' and vn_ngay(t.xu_ly_luc) between p_tu and p_den)
  ), th_tong as (
    select coalesce(sum(thanh_tien), 0) as tien,
           coalesce(sum(thanh_tien) filter (where trang_thai = 'da_nhan_sau'), 0) as tien_sau,
           coalesce(round(sum(so_luong * so_luong_quy_doi * gv_hh) filter (where hang_tot)), 0) as von_ve
      from th
  )
  select jsonb_build_object(
    'tong', (select jsonb_build_object(
        'so_don', count(*),
        'doanh_thu', coalesce(sum(d.dt), 0) - (select tien_sau from th_tong),
        'gia_von', coalesce(round(sum(v.gia_von)), 0) - (select von_ve from th_tong),
        'lai_gop', coalesce(sum(d.dt), 0) - (select tien_sau from th_tong) - coalesce(round(sum(v.gia_von)), 0) + (select von_ve from th_tong),
        'ty_le_co_gia_von', case when sum(d.tong_tien_hang) > 0
                                 then round(100.0 * coalesce(sum(v.dt_co_von), 0) / sum(d.tong_tien_hang)) else 0 end,
        'da_thu', (select coalesce(sum(so_tien), 0) from thanh_toan where hinh_thuc <> 'Cấn trừ' and vn_ngay(ngay) between p_tu and p_den),
        'ghi_no', coalesce(sum(d.tong_cong) filter (where d.hinh_thuc = 'Ghi nợ'), 0),
        'tra_hang', (select tien from th_tong),
        'doi_thuong', coalesce(sum(d.tru_doi_thuong), 0),
        'tra_lai_khach', coalesce(sum(d.tien_tra_lai), 0))
      from dh d left join von v on v.don_hang_id = d.id),
    'theo_ngay', (select coalesce(jsonb_agg(x order by x.ngay), '[]'::jsonb) from (
        select vn_ngay(d.ngay) as ngay, count(*) as so_don, sum(d.dt) as doanh_thu,
               sum(d.dt) - coalesce(round(sum(v.gia_von)), 0) as lai_gop
        from dh d left join von v on v.don_hang_id = d.id group by 1) x),
    'hang_ban_chay', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select hang_hoa_id, max(ten_hang) as ten, sum(so_luong * so_luong_quy_doi) as so_luong_nho,
               sum(thanh_tien) as doanh_thu, count(distinct don_hang_id) as so_don
        from ct group by 1 order by sum(thanh_tien) desc limit 30) x),
    'khach_mua_nhieu', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select d.khach_hang_id, k.ten, count(*) as so_don, sum(d.dt) as doanh_thu
        from dh d join khach_hang k on k.id = d.khach_hang_id
        where d.khach_hang_id <> 'KHLE'
        group by 1, 2 order by sum(d.dt) desc limit 30) x),
    'theo_hinh_thuc', (select coalesce(jsonb_object_agg(hinh_thuc, tien), '{}'::jsonb) from (
        select hinh_thuc, sum(tong_cong) tien from dh group by 1) x)
  ) into v;
  return v;
end $function$;

CREATE OR REPLACE FUNCTION public.tinh_chot_so(p_ngay date DEFAULT NULL::date)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  d date := coalesce(p_ngay, vn_ngay(now()));
  v_quy bigint; v_tm bigint; v_chi bigint; v_ck bigint; v_no bigint; v_don int; v_cho int;
  v_tra_lai bigint; v_chi_treo bigint; v_nap bigint; v_tra_hang bigint; v_thuong bigint; v_cho_kt int;
begin
  perform _bat_buoc_chu();
  select de_lai into v_quy from chot_so where ngay < d order by ngay desc limit 1;
  select coalesce(sum(so_tien) filter (where hinh_thuc = 'Tiền mặt'), 0), coalesce(sum(so_tien) filter (where hinh_thuc = 'Chuyển khoản'), 0)
    into v_tm, v_ck from thanh_toan where vn_ngay(ngay) = d;
  select coalesce(sum(so_tien), 0) into v_chi from tra_ncc where hinh_thuc = 'Tiền mặt' and vn_ngay(ngay) = d;
  select count(*), coalesce(sum(tong_cong) filter (where hinh_thuc = 'Ghi nợ'), 0),
         coalesce(sum(tien_tra_lai), 0), coalesce(sum(tru_tra_hang), 0), coalesce(sum(tru_doi_thuong), 0)
    into v_don, v_no, v_tra_lai, v_tra_hang, v_thuong
    from don_hang where vn_ngay(ngay) = d and trang_thai = 'hoan_tat';
  select coalesce(sum(tien_mat_chi), 0) into v_chi_treo from viec_treo_khach where trang_thai = 'xong' and vn_ngay(xu_ly_luc) = d;
  select coalesce(sum(tong_tien), 0) into v_nap from doi_nap_ncc where cach = 'tien_mat' and vn_ngay(ngay) = d;
  select count(*) into v_cho from don_hang where not da_giao and trang_thai = 'hoan_tat';
  select count(*) into v_cho_kt from viec_treo_khach where trang_thai = 'mo' and loai = 'cho_kiem_tra';
  return jsonb_build_object('ngay', d, 'quy_dau', v_quy,
    'thu_tm', v_tm + v_nap, 'chi_tm', v_chi + v_tra_lai + v_chi_treo, 'thu_ck', v_ck,
    'thu_khach_tm', v_tm, 'thu_nap_ncc', v_nap, 'tra_ncc_tm', v_chi, 'tra_lai_khach', v_tra_lai + v_chi_treo,
    'tru_tra_hang', v_tra_hang, 'tru_doi_thuong', v_thuong, 'cho_kiem_tra', v_cho_kt,
    'ban_no', v_no, 'so_don', v_don, 'cho_giao', v_cho, 'da_chot', (select to_jsonb(c) from chot_so c where ngay = d));
end $function$;

CREATE OR REPLACE FUNCTION public.luu_chot_so(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  t jsonb; v_quy bigint; v_phai bigint; v_dem bigint := _tien(p->>'dem_thuc'); v_rut bigint := coalesce(_tien(p->>'rut_ra'), 0);
begin
  perform _bat_buoc_chu();
  t := tinh_chot_so((p->>'ngay')::date);
  if v_dem is null or v_dem < 0 then raise exception 'Chưa nhập số tiền đếm được'; end if;
  if v_rut < 0 or v_rut > v_dem then raise exception 'Số rút ra phải từ 0 đến số tiền đếm được'; end if;
  v_quy := coalesce(_tien(p->>'quy_dau'), (t->>'quy_dau')::bigint, 0);
  v_phai := v_quy + (t->>'thu_tm')::bigint - (t->>'chi_tm')::bigint;
  insert into chot_so (ngay, quy_dau, thu_tm, chi_tm, thu_ck, ban_no, phai_co, dem_thuc, lech, rut_ra, de_lai, ghi_chu, nguoi_chot)
  values ((t->>'ngay')::date, v_quy, (t->>'thu_tm')::bigint, (t->>'chi_tm')::bigint, (t->>'thu_ck')::bigint, (t->>'ban_no')::bigint,
          v_phai, v_dem, v_dem - v_phai, v_rut, v_dem - v_rut, nullif(trim(p->>'ghi_chu'), ''), _ten_nguoi_dung())
  on conflict (ngay) do update set quy_dau = excluded.quy_dau, thu_tm = excluded.thu_tm, chi_tm = excluded.chi_tm,
    thu_ck = excluded.thu_ck, ban_no = excluded.ban_no, phai_co = excluded.phai_co, dem_thuc = excluded.dem_thuc,
    lech = excluded.lech, rut_ra = excluded.rut_ra, de_lai = excluded.de_lai, ghi_chu = excluded.ghi_chu,
    nguoi_chot = excluded.nguoi_chot, chot_luc = now();
  return (select to_jsonb(c) from chot_so c where ngay = (t->>'ngay')::date);
end $function$;

CREATE OR REPLACE FUNCTION public.tao_don_hang(p jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  v_kh    text := nullif(trim(p->>'khach_hang_id'), '');
  v_ht    text := coalesce(nullif(p->>'hinh_thuc', ''), 'Ghi nợ');
  v_ck    bigint := coalesce(_tien(p->>'chiet_khau'), 0);
  v_nv    text := _ten_nguoi_dung();
  v_ten_moi text := nullif(trim(p#>>'{khach_moi,ten}'), '');
  v_sdt_moi text := nullif(regexp_replace(coalesce(p#>>'{khach_moi,sdt}', ''), '\D', '', 'g'), '');
  v_dh    text;
  v_it    jsonb;
  v_hh    hang_hoa%rowtype;
  v_bg    bang_gia%rowtype;
  v_co_gia boolean;
  v_qc    text;
  v_sl    numeric;
  v_qd    numeric;
  v_gia   bigint;
  v_giam  bigint;
  v_tt    bigint;
  v_tong  bigint := 0;
  v_stt   int := 0;
  v_cong  bigint;
  v_ma    text := nullif(trim(p->>'ma_phieu'), '');
  v_giao  boolean := coalesce((p->>'can_giao')::boolean, true);
  -- TH01
  v_tra   bigint := 0;   -- tổng tiền trả hàng được trừ
  v_thg   bigint := 0;   -- tổng tiền thưởng trừ vào đơn
  v_treo  bigint := 0;   -- khoản treo (mình nợ khách) trừ vào đơn
  v_con   bigint;        -- còn lại sau khi trừ (có thể âm)
  v_du    bigint := 0;
  v_cantru bigint := 0;
  v_ctl   chuong_trinh_thuong%rowtype;
  v_muc   jsonb;
  v_nap   int;
  v_duoc  numeric;      -- số còn được trả (đơn vị nhỏ nhất)
  v_sl1   numeric;      -- phần được trừ (theo quy cách)
  v_sl2   numeric;      -- phần chờ kiểm tra
  v_th_id text;
  v_dt_id bigint;
  v_cho   int := 0;     -- số dòng chờ chủ kiểm tra
  v_vt    viec_treo_khach%rowtype;
  v_tt_tra text;
begin
  perform _bat_buoc_nhan_vien();
  if v_ma is not null then
    perform pg_advisory_xact_lock(hashtext('don:' || v_ma));
    select jsonb_build_object('id', id, 'khach_hang_id', khach_hang_id, 'tong_cong', tong_cong, 'hinh_thuc', hinh_thuc,
                              'tien_tra_lai', tien_tra_lai, 'tien_can_tru', tien_can_tru, 'trung', true)
      into v_it from don_hang where ma_phieu = v_ma;
    if v_it is not null then return v_it; end if;
  end if;
  if v_ht not in ('Tiền mặt', 'Chuyển khoản', 'Ghi nợ') then
    raise exception 'Hình thức thanh toán không hợp lệ: %', v_ht;
  end if;
  if coalesce(jsonb_array_length(case when jsonb_typeof(p->'items') = 'array' then p->'items' end), 0)
   + coalesce(jsonb_array_length(case when jsonb_typeof(p->'tra_hang') = 'array' then p->'tra_hang' end), 0)
   + coalesce(jsonb_array_length(case when jsonb_typeof(p->'doi_thuong') = 'array' then p->'doi_thuong' end), 0)
   + coalesce(jsonb_array_length(case when jsonb_typeof(p->'tru_treo') = 'array' then p->'tru_treo' end), 0) = 0 then
    raise exception 'Đơn chưa có mặt hàng nào';
  end if;

  if v_kh is null and v_ten_moi is not null then
    select id into v_kh from khach_hang
     where (v_sdt_moi is not null and regexp_replace(coalesce(sdt, ''), '\D', '', 'g') = v_sdt_moi)
        or lower(trim(ten)) = lower(v_ten_moi)
     order by tao_luc limit 1;
    if v_kh is null then
      insert into khach_hang (ten, sdt) values (v_ten_moi, nullif(trim(p#>>'{khach_moi,sdt}'), ''))
      returning id into v_kh;
    end if;
  end if;
  v_kh := coalesce(v_kh, 'KHLE');
  if not exists (select 1 from khach_hang where id = v_kh) then
    raise exception 'Không tìm thấy khách hàng %', v_kh;
  end if;

  insert into don_hang (khach_hang_id, nhan_vien_id, nguoi_tao, kenh, hinh_thuc, ghi_chu, ma_phieu, da_giao, giao_luc)
  values (v_kh, auth.uid(), v_nv, coalesce(nullif(p->>'kenh', ''), 'Zalo'), v_ht, nullif(trim(p->>'ghi_chu'), ''), v_ma,
          not v_giao, case when v_giao then null else now() end)
  returning id into v_dh;

  -- (a) Hàng bán – như cũ
  for v_it in select * from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) loop
    v_stt := v_stt + 1;
    select * into v_hh from hang_hoa where id = v_it->>'hang_hoa_id';
    if not found then raise exception 'Không tìm thấy mặt hàng %', v_it->>'hang_hoa_id'; end if;
    v_qc := coalesce(nullif(trim(v_it->>'quy_cach'), ''), v_hh.don_vi);
    v_sl := nullif(trim(v_it->>'so_luong'), '')::numeric;
    if v_sl is null or v_sl <= 0 then raise exception 'Số lượng không hợp lệ: %', v_hh.ten; end if;
    select * into v_bg from bang_gia
     where hang_hoa_id = v_hh.id and lower(quy_cach) = lower(v_qc) and dang_ap_dung limit 1;
    v_co_gia := found;
    v_qd   := case when v_co_gia then v_bg.so_luong_quy_doi
                   else coalesce(nullif(trim(v_it->>'so_luong_quy_doi'), '')::numeric, 1) end;
    v_gia  := coalesce(_tien(v_it->>'don_gia'), case when v_co_gia then v_bg.gia_ban end);
    if v_gia is null or v_gia <= 0 then
      raise exception '"%" chưa có giá cho quy cách "%"', v_hh.ten, v_qc;
    end if;
    v_giam := least(greatest(coalesce(_tien(v_it->>'giam_gia'), 0), 0), v_gia);   -- giảm giá không âm, không quá đơn giá
    v_tt   := round(v_sl * (v_gia - v_giam));
    insert into don_hang_ct (don_hang_id, stt, hang_hoa_id, ten_hang, quy_cach, so_luong_quy_doi,
                             so_luong, don_gia, giam_gia, thanh_tien, gia_von)
    values (v_dh, v_stt, v_hh.id, v_hh.ten, v_qc, v_qd, v_sl, v_gia, v_giam, v_tt, v_hh.gia_von);
    v_tong := v_tong + v_tt;
    if not v_co_gia and coalesce((v_it->>'luu_gia')::boolean, false) then
      insert into bang_gia (hang_hoa_id, quy_cach, so_luong_quy_doi, gia_ban)
      values (v_hh.id, v_qc, v_qd, v_gia) on conflict do nothing;
    end if;
    update hang_hoa set ton_kho = ton_kho - v_sl * v_qd where id = v_hh.id and ton_kho is not null;
  end loop;

  -- (b) TRẢ HÀNG – chỉ trừ tiền phần khách THẬT SỰ đã mua; phần còn lại chờ chủ kiểm tra
  for v_it in select * from jsonb_array_elements(coalesce(p->'tra_hang', '[]'::jsonb)) loop
    select * into v_hh from hang_hoa where id = v_it->>'hang_hoa_id';
    if not found then raise exception 'Không tìm thấy mặt hàng trả %', v_it->>'hang_hoa_id'; end if;
    v_qc := coalesce(nullif(trim(v_it->>'quy_cach'), ''), v_hh.don_vi);
    v_sl := nullif(trim(v_it->>'so_luong'), '')::numeric;
    if v_sl is null or v_sl <= 0 then raise exception 'Số lượng trả không hợp lệ: %', v_hh.ten; end if;
    v_qd := coalesce(nullif(trim(v_it->>'so_luong_quy_doi'), '')::numeric,
                     (select so_luong_quy_doi from bang_gia where hang_hoa_id = v_hh.id and lower(quy_cach) = lower(v_qc) and dang_ap_dung limit 1), 1);
    if v_qd <= 0 then v_qd := 1; end if;
    v_gia := _tien(v_it->>'don_gia');
    if v_gia is null or v_gia < 0 then raise exception 'Giá trả hàng không hợp lệ: %', v_hh.ten; end if;

    -- Khách muốn đổi lấy hàng mới sau → không trừ tiền, ghi việc treo "khách lấy lại"
    if coalesce((v_it->>'doi_lay_lai')::boolean, false) then
      v_duoc := _con_duoc_tra(v_kh, v_hh.id);
      if v_duoc < v_sl * v_qd then   -- chưa mua / trả quá → vẫn phải chờ chủ kiểm tra
        v_tt_tra := 'cho_kiem_tra';
      else
        v_tt_tra := 'doi_lay_lai';
      end if;
      insert into tra_hang (don_hang_id, khach_hang_id, hang_hoa_id, ten_hang, quy_cach, so_luong_quy_doi, so_luong, don_gia, thanh_tien,
                            ly_do, hang_tot, trang_thai, nguoi_tao, nhan_vien_id)
      values (v_dh, v_kh, v_hh.id, v_hh.ten, v_qc, v_qd, v_sl, v_gia, 0, nullif(trim(v_it->>'ly_do'), ''),
              coalesce((v_it->>'hang_tot')::boolean, true), v_tt_tra, v_nv, auth.uid())
      returning id into v_th_id;
      if v_tt_tra = 'doi_lay_lai' then
        if coalesce((v_it->>'hang_tot')::boolean, true) then
          update hang_hoa set ton_kho = ton_kho + v_sl * v_qd where id = v_hh.id and ton_kho is not null;
        end if;
        insert into viec_treo_khach (khach_hang_id, loai, noi_dung, hang_hoa_id, so_luong, tra_hang_id, don_hang_id, nguoi_tao)
        values (v_kh, 'kh_lay_lai', format('Khách đã trả %s %s %s – chờ lấy lại hàng mới', so_dep(v_sl), v_qc, v_hh.ten),
                v_hh.id, v_sl * v_qd, v_th_id, v_dh, v_nv);
      else
        v_cho := v_cho + 1;
        insert into viec_treo_khach (khach_hang_id, loai, noi_dung, hang_hoa_id, so_luong, so_tien, tra_hang_id, don_hang_id, nguoi_tao)
        values (v_kh, 'cho_kiem_tra', format('Trả %s %s %s (muốn đổi hàng mới) – %s', so_dep(v_sl), v_qc, v_hh.ten,
                case when v_kh = 'KHLE' then 'khách lẻ, chủ kiểm tra' else 'chưa mua đủ số này, chủ kiểm tra' end),
                v_hh.id, v_sl * v_qd, 0, v_th_id, v_dh, v_nv);
      end if;
      continue;
    end if;

    -- Chia: phần được trừ tiền (≤ số còn được trả) và phần chờ kiểm tra
    v_duoc := _con_duoc_tra(v_kh, v_hh.id);
    v_sl1  := least(v_sl, floor(v_duoc / v_qd * 1000) / 1000);
    if v_sl1 < 0 then v_sl1 := 0; end if;
    v_sl2  := v_sl - v_sl1;
    if v_sl1 > 0 then
      v_tt := round(v_sl1 * v_gia);
      insert into tra_hang (don_hang_id, khach_hang_id, hang_hoa_id, ten_hang, quy_cach, so_luong_quy_doi, so_luong, don_gia, thanh_tien,
                            ly_do, hang_tot, trang_thai, nguoi_tao, nhan_vien_id)
      values (v_dh, v_kh, v_hh.id, v_hh.ten, v_qc, v_qd, v_sl1, v_gia, v_tt, nullif(trim(v_it->>'ly_do'), ''),
              coalesce((v_it->>'hang_tot')::boolean, true), 'da_tru', v_nv, auth.uid());
      v_tra := v_tra + v_tt;
      if coalesce((v_it->>'hang_tot')::boolean, true) then
        update hang_hoa set ton_kho = ton_kho + v_sl1 * v_qd where id = v_hh.id and ton_kho is not null;
      end if;
    end if;
    if v_sl2 > 0 then
      v_cho := v_cho + 1;
      insert into tra_hang (don_hang_id, khach_hang_id, hang_hoa_id, ten_hang, quy_cach, so_luong_quy_doi, so_luong, don_gia, thanh_tien,
                            ly_do, hang_tot, trang_thai, nguoi_tao, nhan_vien_id)
      values (v_dh, v_kh, v_hh.id, v_hh.ten, v_qc, v_qd, v_sl2, v_gia, round(v_sl2 * v_gia), nullif(trim(v_it->>'ly_do'), ''),
              coalesce((v_it->>'hang_tot')::boolean, true), 'cho_kiem_tra', v_nv, auth.uid())
      returning id into v_th_id;
      insert into viec_treo_khach (khach_hang_id, loai, noi_dung, so_tien, hang_hoa_id, so_luong, tra_hang_id, don_hang_id, nguoi_tao)
      values (v_kh, 'cho_kiem_tra',
              format('Trả %s %s %s = %s đ – %s', so_dep(v_sl2), v_qc, v_hh.ten, so_dep(round(v_sl2 * v_gia)),
                     case when v_kh = 'KHLE' then 'khách lẻ, chủ kiểm tra'
                          when v_sl1 > 0 then 'vượt số khách đã mua, chủ kiểm tra'
                          else 'khách chưa từng mua món này, chủ kiểm tra' end),
              round(v_sl2 * v_gia), v_hh.id, v_sl2 * v_qd, v_th_id, v_dh, v_nv);
    end if;
  end loop;

  -- (c) ĐỔI THƯỞNG NẮP theo chương trình
  for v_it in select * from jsonb_array_elements(coalesce(p->'doi_thuong', '[]'::jsonb)) loop
    select * into v_ctl from chuong_trinh_thuong where id = v_it->>'chuong_trinh_id';
    if not found then raise exception 'Không tìm thấy chương trình thưởng %', v_it->>'chuong_trinh_id'; end if;
    select m into v_muc from jsonb_array_elements(v_ctl.muc) m where m->>'ten' = v_it->>'muc' limit 1;
    if v_muc is null then raise exception 'Chương trình "%" không có mức "%"', v_ctl.ten, v_it->>'muc'; end if;
    v_nap := nullif(trim(v_it->>'so_nap'), '')::int;
    if v_nap is null or v_nap <= 0 then raise exception 'Số nắp không hợp lệ'; end if;
    insert into doi_thuong (don_hang_id, khach_hang_id, chuong_trinh_id, muc_ten, loai, gia_tri, hang_hoa_id, so_luong_hang, so_nap,
                            da_tra_khach, nguoi_tao, nhan_vien_id)
    values (v_dh, v_kh, v_ctl.id, v_muc->>'ten', v_muc->>'loai', coalesce((v_muc->>'gia_tri')::bigint, 0),
            nullif(v_muc->>'hang_hoa_id', ''), coalesce((v_muc->>'so_luong')::numeric, 0), v_nap,
            not coalesce((v_it->>'chua_tra')::boolean, false), v_nv, auth.uid())
    returning id into v_dt_id;
    if coalesce((v_it->>'chua_tra')::boolean, false) then
      -- Chưa trả khách ngay → ghi việc treo để đơn sau nhắc
      if v_muc->>'loai' = 'tien' then
        insert into viec_treo_khach (khach_hang_id, loai, noi_dung, so_tien, doi_thuong_id, don_hang_id, nguoi_tao)
        values (v_kh, 'no_thuong_tien', format('Nợ khách thưởng %s × %s = %s đ (%s)', v_nap, v_muc->>'ten',
                so_dep(v_nap * (v_muc->>'gia_tri')::bigint), v_ctl.ten), v_nap * (v_muc->>'gia_tri')::bigint, v_dt_id, v_dh, v_nv);
      else
        insert into viec_treo_khach (khach_hang_id, loai, noi_dung, hang_hoa_id, so_luong, doi_thuong_id, don_hang_id, nguoi_tao)
        values (v_kh, 'no_thuong_hang', format('Nợ khách %s × %s (%s)', v_nap, v_muc->>'ten', v_ctl.ten),
                nullif(v_muc->>'hang_hoa_id', ''), v_nap * coalesce((v_muc->>'so_luong')::numeric, 0), v_dt_id, v_dh, v_nv);
      end if;
    elsif v_muc->>'loai' = 'tien' then
      v_thg := v_thg + v_nap * (v_muc->>'gia_tri')::bigint;
    else
      -- Thưởng lon: đưa khách hàng thật → trừ tồn kho, 0đ
      update hang_hoa set ton_kho = ton_kho - v_nap * coalesce((v_muc->>'so_luong')::numeric, 0)
       where id = v_muc->>'hang_hoa_id' and ton_kho is not null;
    end if;
  end loop;

  -- (d) Khoản mình nợ khách từ trước (thưởng chưa trả, trả hàng chủ đã nhận) → trừ vào đơn này. Chỉ chủ.
  for v_it in select * from jsonb_array_elements(coalesce(p->'tru_treo', '[]'::jsonb)) loop
    perform _bat_buoc_chu();
    select * into v_vt from viec_treo_khach where id = (v_it #>> '{}')::bigint for update;
    if not found or v_vt.trang_thai <> 'mo' or v_vt.khach_hang_id <> v_kh or v_vt.loai not in ('no_thuong_tien', 'no_tien') then
      raise exception 'Khoản treo % không trừ được vào đơn này', v_it #>> '{}';
    end if;
    v_treo := v_treo + v_vt.so_tien;
    update viec_treo_khach set trang_thai = 'xong', ket_qua = 'Trừ vào đơn ' || v_dh, xu_ly_luc = now(), nguoi_xu_ly = v_nv where id = v_vt.id;
    if v_vt.doi_thuong_id is not null then update doi_thuong set da_tra_khach = true where id = v_vt.doi_thuong_id; end if;
  end loop;

  -- (e) Tính tiền
  v_con := greatest(v_tong - v_ck, 0) - v_tra - v_thg - v_treo;
  v_cong := greatest(v_con, 0);
  v_du := greatest(-v_con, 0);
  if v_kh = 'KHLE' and v_ht = 'Ghi nợ' and v_cong > 0 then
    raise exception 'Ghi nợ thì phải chọn hoặc nhập tên khách hàng';
  end if;
  if v_du > 0 then v_cantru := _can_tru_no(v_kh, v_du, v_dh, 'Trừ từ trả hàng/đổi thưởng đơn ' || v_dh); end if;

  update don_hang set tong_tien_hang = v_tong, chiet_khau = v_ck, tong_cong = v_cong,
         tru_tra_hang = v_tra, tru_doi_thuong = v_thg, tru_khac = v_treo,
         tien_can_tru = v_cantru, tien_tra_lai = v_du - v_cantru,
         dt_thuan = greatest(v_tong - v_ck, 0) - v_tra
   where id = v_dh;

  if v_ht = 'Tiền mặt' and v_cong > 0 then
    insert into thanh_toan (khach_hang_id, don_hang_id, so_tien, hinh_thuc, nhan_vien_id, nguoi_thu)
    values (v_kh, v_dh, v_cong, 'Tiền mặt', auth.uid(), v_nv);
  end if;

  return jsonb_build_object('id', v_dh, 'khach_hang_id', v_kh, 'tong_cong', v_cong, 'hinh_thuc', v_ht,
    'tru_tra_hang', v_tra, 'tru_doi_thuong', v_thg, 'tru_khac', v_treo,
    'tien_can_tru', v_cantru, 'tien_tra_lai', v_du - v_cantru, 'cho_kiem_tra', v_cho);
end $function$;

drop policy if exists nv_sua_khach on khach_hang;
drop policy if exists nv_them_khach on khach_hang;
create policy nv_sua_khach on khach_hang for update using (la_nhan_vien()) with check (la_nhan_vien());
create policy nv_them_khach on khach_hang for insert with check (la_nhan_vien());
drop function if exists gui_yeu_cau_duyet(jsonb), xu_ly_yeu_cau_duyet(bigint, boolean), dat_quyen_nv(uuid, jsonb), _can_quyen(text), co_quyen(text), _ten_quyen(text);
drop table if exists yeu_cau_duyet;
alter table nhan_vien drop column if exists quyen;
commit;
notify pgrst, 'reload schema';
