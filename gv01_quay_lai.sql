-- QUAY LẠI GV01: trả 2 hàm nhập toa về bản trước GV01 (giá vốn = giá nhập gần nhất), xoá view + hàm phụ.
begin;
CREATE OR REPLACE FUNCTION public._go_ct_toa(p_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  update hang_hoa h set ton_kho = h.ton_kho - c.sl
  from (select hang_hoa_id, sum(so_luong * so_luong_quy_doi) sl from phieu_nhap_ct
         where phieu_nhap_id = p_id and cong_ton group by 1) c
  where h.id = c.hang_hoa_id and h.ton_kho is not null;
  update hang_hoa h set gia_von = c.gia_von_cu
  from phieu_nhap_ct c
  where c.phieu_nhap_id = p_id and h.id = c.hang_hoa_id and c.gia_von_cu is not null and c.don_gia_nhap > 0
    and h.gia_von = round(c.don_gia_nhap / c.so_luong_quy_doi);
end $function$
;
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
  perform _bat_buoc_nhan_vien(); perform _can_quyen('nhap_toa');
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

drop view if exists v_gia_nhap_ncc;
drop function if exists _toa_cuoi_cung(text);
commit;
notify pgrst, 'reload schema';
