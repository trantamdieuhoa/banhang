-- ═══════════════════════════════════════════════════════════════════
-- GV01 – GIÁ VỐN BÌNH QUÂN + GIÁ NHẬP THEO NCC (anh Tâm duyệt 13/11/2026)
-- • Món chủ lực (có theo dõi tồn): giá vốn = bình quân gia quyền. Món không theo dõi tồn: giá nhập gần nhất (như cũ).
-- • Dòng toa có thể kèm "dem_con" (đếm còn lại, đơn vị nhỏ nhất) → sửa tồn (ghi kiểm kho) TRƯỚC khi tính bình quân.
-- • Dòng giá 0đ: giữ giá vốn (chưa nhập giá); riêng dòng "tang" = hàng tặng → tính bình quân với giá 0.
-- • Sửa / huỷ toa: chỉ khôi phục giá vốn với món mà toa này là lần nhập SAU CÙNG; món đã có toa mới hơn → giữ giá vốn, báo lại.
-- • View v_gia_nhap_ncc: giá nhập lần cuối của từng NCC cho từng món.
-- Không thêm / xoá cột bảng nào. Quay lại: gv01_quay_lai.sql
-- ═══════════════════════════════════════════════════════════════════
begin;

-- Các món trong toa p_id mà toa này là lần nhập SAU CÙNG (dòng chi tiết có id lớn nhất trong các toa còn hiệu lực)
create or replace function _toa_cuoi_cung(p_id text) returns text[]
language sql stable security definer set search_path = public as $$
  select coalesce(array_agg(distinct c.hang_hoa_id), '{}')
    from phieu_nhap_ct c
   where c.phieu_nhap_id = p_id
     and c.id = (select max(c2.id) from phieu_nhap_ct c2 join phieu_nhap p2 on p2.id = c2.phieu_nhap_id
                  where c2.hang_hoa_id = c.hang_hoa_id and p2.trang_thai = 'hoan_tat');
$$;

-- Gỡ chi tiết toa (trước khi sửa lại / khi huỷ toa): trừ tồn đã cộng; trả giá vốn về trước toa (chỉ món mà toa này là lần nhập sau cùng)
CREATE OR REPLACE FUNCTION public._go_ct_toa(p_id text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare v_cuoi text[] := _toa_cuoi_cung(p_id);
begin
  update hang_hoa h set ton_kho = h.ton_kho - c.sl
  from (select hang_hoa_id, sum(so_luong * so_luong_quy_doi) sl from phieu_nhap_ct
         where phieu_nhap_id = p_id and cong_ton group by 1) c
  where h.id = c.hang_hoa_id and h.ton_kho is not null;
  -- giá vốn trước toa = gia_von_cu của dòng ĐẦU TIÊN của món đó trong toa
  update hang_hoa h set gia_von = c.gia_von_cu
  from (select distinct on (hang_hoa_id) hang_hoa_id, gia_von_cu from phieu_nhap_ct
         where phieu_nhap_id = p_id order by hang_hoa_id, id) c
  where h.id = c.hang_hoa_id and c.hang_hoa_id = any(v_cuoi) and c.gia_von_cu is not null;
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
  v_dem  numeric;
  v_tong bigint := 0;
  v_n    int := 0;
  v_ton  int := 0;
  v_tang jsonb := '[]'::jsonb;
  v_co_ct  boolean;
  v_cuoi   text[];
  v_giu    text[] := '{}';   -- món đã có toa mới hơn → không tính lại giá vốn
  v_da_dem text[] := '{}';
begin
  perform _bat_buoc_nhan_vien(); perform _can_quyen('nhap_toa');
  select * into v_pn from phieu_nhap where id = p_id for update;
  if not found or v_pn.trang_thai <> 'hoan_tat' then raise exception 'Không tìm thấy toa % (hoặc đã huỷ)', p_id; end if;
  if jsonb_typeof(p_items) is distinct from 'array' then raise exception 'Chi tiết toa không hợp lệ'; end if;

  -- Toa đã có chi tiết (đang SỬA): món nào toa này không còn là lần nhập sau cùng thì giữ giá vốn
  v_co_ct := exists (select 1 from phieu_nhap_ct where phieu_nhap_id = p_id);
  if v_co_ct then
    v_cuoi := _toa_cuoi_cung(p_id);
    select coalesce(array_agg(distinct hang_hoa_id), '{}') into v_giu from phieu_nhap_ct
     where phieu_nhap_id = p_id and not (hang_hoa_id = any(v_cuoi));
  end if;

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

    -- "Đếm còn lại" (chỉ món chủ lực, mỗi món 1 lần): sửa tồn về số đếm, ghi nhật ký kiểm kho
    v_dem := nullif(trim(v_it->>'dem_con'), '')::numeric;
    if v_dem is not null and v_hh.ton_kho is not null and not (v_hh.id = any(v_da_dem)) then
      if v_dem < 0 then raise exception 'Số đếm còn lại không hợp lệ: %', v_hh.ten; end if;
      insert into kiem_kho (hang_hoa_id, ton_cu, ton_moi, nguoi) values (v_hh.id, v_hh.ton_kho, v_dem, _ten_nguoi_dung() || ' (lúc nhập toa ' || p_id || ')');
      update hang_hoa set ton_kho = v_dem where id = v_hh.id;
      v_hh.ton_kho := v_dem; v_da_dem := v_da_dem || v_hh.id;
    end if;

    -- Giá vốn mới (đơn vị nhỏ nhất)
    v_gv := null;
    if v_hh.id = any(v_giu) then
      v_gv := null;                                                    -- đã có toa mới hơn: không đụng
    elsif v_hh.ton_kho is null then
      if v_gia > 0 then v_gv := round(v_gia / v_qd); end if;           -- không theo dõi tồn: giá gần nhất
    elsif v_gia > 0 or coalesce((v_it->>'tang')::boolean, false) then
      if v_hh.ton_kho <= 0 or coalesce(v_hh.gia_von, 0) <= 0 then
        v_gv := case when v_gia > 0 then round(v_gia / v_qd) end;      -- hết hàng / chưa có vốn: lấy giá nhập
      else
        v_gv := round((v_hh.ton_kho * v_hh.gia_von + v_sl * v_qd * (v_gia / v_qd)) / (v_hh.ton_kho + v_sl * v_qd));
      end if;
    end if;

    insert into phieu_nhap_ct (phieu_nhap_id, hang_hoa_id, ten_hang, quy_cach, so_luong_quy_doi, so_luong,
                               don_gia_nhap, thanh_tien, cong_ton, gia_von_cu)
    values (p_id, v_hh.id, v_hh.ten, v_qc, v_qd, v_sl, v_gia, round(v_sl * v_gia), v_hh.ton_kho is not null, v_hh.gia_von);
    v_tong := v_tong + round(v_sl * v_gia);
    v_n := v_n + 1;
    if v_hh.ton_kho is not null then v_ton := v_ton + 1; end if;

    -- Giá vốn TĂNG (đã có giá vốn cũ) → báo cho app gợi ý giá bán mới (theo giá vốn bình quân mới)
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
    if v_pn.ncc_id is not null then
      insert into ncc_hang (ncc_id, hang_hoa_id) values (v_pn.ncc_id, v_hh.id) on conflict do nothing;
    end if;
  end loop;

  return jsonb_build_object('so_dong', v_n, 'tong_ct', v_tong, 'cong_ton', v_ton, 'tang', v_tang,
    'gv_giu', (select coalesce(jsonb_agg(ten), '[]'::jsonb) from hang_hoa where id = any(v_giu)));
end $function$;

-- Giá nhập lần cuối của từng NCC cho từng món (chỉ toa còn hiệu lực, có giá). security_invoker: theo quyền người xem.
create or replace view v_gia_nhap_ncc with (security_invoker = true) as
select distinct on (c.hang_hoa_id, p.ncc_id)
       c.hang_hoa_id, p.ncc_id, n.ten as ncc_ten, n.dang_hop_tac, p.id as phieu_nhap_id, p.ngay,
       c.quy_cach, c.so_luong_quy_doi, c.don_gia_nhap,
       round(c.don_gia_nhap / c.so_luong_quy_doi) as gia_dv,
       count(*) over (partition by c.hang_hoa_id, p.ncc_id) as so_lan
  from phieu_nhap_ct c
  join phieu_nhap p on p.id = c.phieu_nhap_id
  join nha_cung_cap n on n.id = p.ncc_id
 where p.trang_thai = 'hoan_tat' and c.don_gia_nhap > 0
 order by c.hang_hoa_id, p.ncc_id, p.ngay desc, c.id desc;
grant select on v_gia_nhap_ncc to authenticated;

commit;
notify pgrst, 'reload schema';
