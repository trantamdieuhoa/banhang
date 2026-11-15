-- PQ03c – SỬA LỖI: tên 2 quyền mới hiện mã tiếng Anh (them_hang, them_ncc) trong Nhật ký thay đổi
-- và trong thông báo thiếu quyền, vì hàm _ten_quyen chưa có 2 quyền này. Chỉ thay hàm, không đụng dữ liệu.
-- Dòng nhật ký đã ghi trước khi sửa vẫn giữ nguyên chữ cũ.
create or replace function _ten_quyen(k text) returns text
language sql immutable as $$
  select case k when 'sua_gia_gio' then 'sửa giá trong giỏ' when 'doi_gia_ban' then 'đổi giá bảng giá' when 'chiet_khau' then 'chiết khấu'
    when 'ghi_no' then 'bán ghi nợ' when 'vuot_han_muc' then 'vượt hạn mức nợ' when 'thu_no' then 'thu tiền nợ' when 'xem_no' then 'xem nợ khách'
    when 'huy_don' then 'huỷ đơn' when 'tra_hang' then 'trả hàng / đổi thưởng' when 'sua_khach' then 'thêm/sửa khách'
    when 'nhap_toa' then 'nhập toa, kiểm kho' when 'tra_ncc' then 'trả tiền NCC' when 'bao_cao' then 'báo cáo, chốt sổ'
    when 'them_hang' then 'thêm mặt hàng mới' when 'them_ncc' then 'thêm/sửa nhà cung cấp' else k end
$$;
revoke execute on function _ten_quyen(text) from public, anon;
notify pgrst, 'reload schema';
