-- QUAY LẠI PQ02: xoá hàm them_gia_dau (giá đã nhập vẫn giữ nguyên)
drop function if exists them_gia_dau(jsonb);
notify pgrst, 'reload schema';
