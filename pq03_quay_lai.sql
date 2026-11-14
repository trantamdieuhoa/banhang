-- QUAY LẠI PQ03: bỏ 2 hàm của NV, bỏ dấu "giá chờ duyệt". (Hàng / NCC nhân viên đã thêm vẫn giữ nguyên.)
begin;
drop function if exists nv_them_hang(jsonb);
drop function if exists nv_luu_ncc(jsonb);
drop function if exists duyet_gia(text);
drop trigger if exists trg_danh_dau_gia_nv on bang_gia;
drop function if exists _danh_dau_gia_nv();
alter table bang_gia drop column if exists cho_duyet;
update nhan_vien set quyen = quyen - 'them_hang' - 'them_ncc' where quyen ?| array['them_hang', 'them_ncc'];
commit;
notify pgrst, 'reload schema';
