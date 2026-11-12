-- ═══════════════════════════════════════════════════════════════════
-- NCC01 – HỒ SƠ NHÀ CUNG CẤP ĐẦY ĐỦ (anh Tâm duyệt 12/11/2026)
-- Thêm: ngân hàng/số TK/tên TK (tạo QR), ảnh QR riêng, Zalo NV bán hàng, điều kiện nợ.
-- Không xoá/sửa dữ liệu cũ. Quay lại: chạy ncc01_quay_lai.sql
-- ═══════════════════════════════════════════════════════════════════
begin;
alter table nha_cung_cap add column if not exists bin           text;    -- mã ngân hàng (VietQR)
alter table nha_cung_cap add column if not exists ten_ngan_hang text;
alter table nha_cung_cap add column if not exists so_tk         text;
alter table nha_cung_cap add column if not exists ten_tk        text;    -- tên chủ TK, KHÔNG DẤU IN HOA
alter table nha_cung_cap add column if not exists anh_qr        text[];  -- ảnh mã QR NCC gửi (nếu có, ưu tiên hơn QR tự tạo)
alter table nha_cung_cap add column if not exists zalo_nv       text;    -- số hoặc link Zalo NV bán hàng
alter table nha_cung_cap add column if not exists han_no_ngay   int check (han_no_ngay is null or han_no_ngay between 0 and 365);  -- số ngày được nợ
alter table nha_cung_cap add column if not exists dieu_kien_no  text;    -- VD: nợ gối 1 toa

-- Hạn trả NCC: tiền trả trừ vào toa CŨ NHẤT trước → toa cũ nhất còn nợ; quá số ngày được nợ thì quá hạn
-- qua_han > 0: quá hạn bấy nhiêu ngày · = 0: tới hạn hôm nay · < 0: còn bấy nhiêu ngày
create or replace view v_ncc_han_no with (security_invoker = true) as
with toa as (
  select p.ncc_id, p.id, p.ngay, p.tong_tien,
         sum(p.tong_tien) over (partition by p.ncc_id order by p.ngay, p.id) as cong_don
    from phieu_nhap p where p.trang_thai = 'hoan_tat'
), tra as (select ncc_id, sum(so_tien) da_tra from tra_ncc group by 1),
cu_nhat as (
  select distinct on (t.ncc_id) t.ncc_id, t.id as toa_id, t.ngay
    from toa t left join tra on tra.ncc_id = t.ncc_id
   where t.cong_don > coalesce(tra.da_tra, 0)
   order by t.ncc_id, t.ngay, t.id
)
select n.id, n.ten, n.han_no_ngay, c.toa_id, c.ngay as ngay_toa_cu_nhat, v.con_no,
       (vn_ngay(now()) - (vn_ngay(c.ngay) + n.han_no_ngay)) as qua_han
  from nha_cung_cap n
  join cu_nhat c on c.ncc_id = n.id
  join v_cong_no_ncc v on v.id = n.id
 where n.han_no_ngay is not null and v.con_no > 0;
grant select on v_ncc_han_no to authenticated;

-- Sao lưu Excel: trang NCC có thêm các cột mới
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
     select n.id, n.ten, n.dia_chi, n.sdt, n.nguoi_lien_he, n.sdt_nv, n.zalo_nv, n.lich_giao, n.ghi_chu, n.dang_hop_tac,
            n.ten_ngan_hang, n.so_tk, n.ten_tk, n.han_no_ngay, n.dieu_kien_no,
            (select string_agg(h.ten, ' | ' order by h.ten) from ncc_hang l join hang_hoa h on h.id = l.hang_hoa_id where l.ncc_id = n.id) as mat_hang
       from nha_cung_cap n) x)
) $function$;
commit;
notify pgrst, 'reload schema';
