-- QUAY LẠI NV01: gỡ toàn bộ trigger nhật ký + bảng nhat_ky (MẤT nhật ký đã ghi). Dữ liệu bán hàng không bị ảnh hưởng.
begin;
do $$ declare t text; begin
  foreach t in array array['hang_hoa', 'bang_gia', 'khach_hang', 'nha_cung_cap', 'don_hang', 'don_hang_ct', 'thanh_toan',
                           'phieu_nhap', 'phieu_nhap_ct', 'tra_ncc', 'tra_hang', 'kiem_kho', 'nhan_vien', 'chot_so', 'cau_hinh',
                           'yeu_cau_duyet', 'ma_vach', 'chuong_trinh_thuong'] loop
    execute format('drop trigger if exists trg_nhat_ky on %I', t);
  end loop;
end $$;
drop trigger if exists trg_nhat_ky_don_moi on don_hang;
drop trigger if exists trg_nhat_ky_phieu_moi on phieu_nhap;
drop function if exists _nk_dong();
drop function if exists _nk_don_moi();
drop function if exists _nk_phieu_moi();
drop function if exists _nk_ghi(text, text, text, text, text, int, text, bigint, jsonb, jsonb, jsonb);
drop function if exists _nk_mo_ta(text, text, jsonb, jsonb, jsonb);
drop function if exists _nk_bo_cot(text);
drop function if exists _nk_khac(jsonb, jsonb, text[]);
drop function if exists _nk_nguoi();
drop function if exists _nk_co_bang(text);
drop function if exists _nk_co(text);
drop function if exists _nk_dk(text);
drop table if exists nhat_ky;
commit;
notify pgrst, 'reload schema';
