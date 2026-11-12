-- ═══════════════════════════════════════════════════════════════════
-- KH01 – HỒ SƠ KHÁCH ĐẦY ĐỦ (anh Tâm duyệt 12/11/2026)
-- Thêm: tên chủ quán, SĐT 2, SĐT 3, số Zalo, link Zalo. Không xoá/sửa dữ liệu cũ.
-- Quay lại: chạy kh01_quay_lai.sql
-- ═══════════════════════════════════════════════════════════════════
begin;
-- Cột "ten" giữ nguyên = tên quán (hoặc tên người nếu khách không có quán)
alter table khach_hang add column if not exists ten_chu   text;   -- tên thật chủ quán
alter table khach_hang add column if not exists sdt2      text;
alter table khach_hang add column if not exists sdt3      text;
alter table khach_hang add column if not exists zalo      text;   -- số Zalo (trống = dùng SĐT 1)
alter table khach_hang add column if not exists zalo_link text;   -- link Zalo riêng (trống = app tự tạo zalo.me/<số>)

-- Danh sách khách cho app: trả thêm các cột mới
CREATE OR REPLACE FUNCTION public.lay_khach_hang()
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
  perform _bat_buoc_nhan_vien();
  return (
    select coalesce(jsonb_agg(jsonb_build_object(
        'id', k.id, 'ten', k.ten, 'sdt', k.sdt, 'dia_chi', k.dia_chi, 'nhom', k.nhom,
        'ten_chu', k.ten_chu, 'sdt2', k.sdt2, 'sdt3', k.sdt3, 'zalo', k.zalo, 'zalo_link', k.zalo_link,
        'han_muc_no', k.han_muc_no, 'ghi_chu', k.ghi_chu, 'khoa', k.khoa,
        'con_no', coalesce(c.tong_no, 0)) order by k.ten), '[]'::jsonb)
    from khach_hang k
    left join v_cong_no_khach c on c.id = k.id);
end $function$;

-- Sao lưu Excel: trang "Khách & nợ" có thêm các cột mới
CREATE OR REPLACE FUNCTION public._du_lieu_sao_luu()
 RETURNS jsonb
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
select jsonb_build_object(
  'luc', now(),
  'hang', (select coalesce(jsonb_agg(x order by x.ten), '[]') from (
     select h.id, h.ten, h.don_vi, d.ten as danh_muc, h.gia_von, h.ton_kho, h.ton_toi_thieu, h.dang_ban,
            (select string_agg(b.quy_cach || ' (' || b.so_luong_quy_doi::float8 || ' ' || h.don_vi || '): ' || b.gia_ban, ' | '
                    order by b.so_luong_quy_doi)
               from bang_gia b where b.hang_hoa_id = h.id and b.dang_ap_dung) as bang_gia,
            (select string_agg(m.ma || coalesce(' (' || m.quy_cach || ')', ''), ' | ' order by m.tao_luc)
               from ma_vach m where m.hang_hoa_id = h.id) as ma_vach
       from hang_hoa h left join danh_muc d on d.id = h.danh_muc_id) x),
  'khach', (select coalesce(jsonb_agg(x order by x.dang_no desc, x.ten), '[]') from (
     select k.id, k.ten, k.ten_chu, k.sdt, k.sdt2, k.sdt3, k.zalo, k.zalo_link, k.dia_chi, k.nhom, k.han_muc_no, coalesce(c.tong_no, 0) as dang_no,
            coalesce(c.so_don_no, 0) as so_don_no, c.ngay_no_cu_nhat
       from khach_hang k left join v_cong_no_khach c on c.id = k.id) x),
  -- Đơn 35 ngày gần nhất + MỌI đơn còn nợ (bằng chứng công nợ)
  'don', (select coalesce(jsonb_agg(x order by x.ngay desc), '[]') from (
     select d.id, d.ngay, d.ten_khach, d.hinh_thuc, d.tong_tien_hang, d.chiet_khau, d.tong_cong, d.da_tra, d.con_no,
            d.trang_thai, d.nguoi_tao, d.ghi_chu
       from v_don_hang d where d.ngay >= now() - interval '35 days' or d.con_no > 0) x),
  'chi_tiet', (select coalesce(jsonb_agg(x order by x.don_hang_id desc, x.stt), '[]') from (
     select c.don_hang_id, c.stt, c.ten_hang, c.quy_cach, c.so_luong, c.don_gia, c.thanh_tien
       from don_hang_ct c join v_don_hang d on d.id = c.don_hang_id
      where d.ngay >= now() - interval '35 days' or d.con_no > 0) x),
  'no_ncc', (select coalesce(jsonb_agg(x), '[]') from (select * from v_cong_no_ncc where con_no <> 0) x),
  'ncc', (select coalesce(jsonb_agg(x order by x.ten), '[]') from (
     select n.id, n.ten, n.dia_chi, n.sdt, n.nguoi_lien_he, n.sdt_nv, n.lich_giao, n.ghi_chu, n.dang_hop_tac,
            (select string_agg(h.ten, ' | ' order by h.ten) from ncc_hang l join hang_hoa h on h.id = l.hang_hoa_id where l.ncc_id = n.id) as mat_hang
       from nha_cung_cap n) x)
) $function$;
commit;
notify pgrst, 'reload schema';
