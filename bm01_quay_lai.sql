-- QUAY LẠI BM01: trả quyền gọi hàm như trước, bỏ nhật ký sao lưu + tự xoá tin AI.
-- (Tài khoản Máy marketing KHÔNG tự bật lại – chủ bật trong app nếu cần.)
begin;
drop trigger if exists trg_xoa_tin_ai_cu on ai_doc_don;
drop function if exists _xoa_tin_ai_cu();
create or replace function sao_luu(p_ma text) returns jsonb
language plpgsql security definer set search_path = public as $$
begin
  if p_ma is null or length(p_ma) < 32 or not exists (select 1 from bi_mat where khoa = 'ma_sao_luu' and gia_tri = p_ma) then
    raise exception 'Sai mã sao lưu';
  end if;
  return _du_lieu_sao_luu();
end $$;
drop table if exists nhat_ky_sao_luu;
-- Trả đúng 11 hàm người ngoài gọi được trên máy chủ thật trước BM01 (đo ngày 13/11/2026)
alter default privileges grant execute on functions to public;
grant execute on function _can_quyen(text), _toa_cuoi_cung(text), co_quyen(text), dat_quyen_nv(uuid, jsonb), doi_nap_ncc(jsonb),
  gia_tra_hang(text, text, text), gui_yeu_cau_duyet(jsonb), luu_chuong_trinh(jsonb), sao_luu(text), xu_ly_viec_treo(bigint, text, text),
  xu_ly_yeu_cau_duyet(bigint, boolean) to anon;
commit;
notify pgrst, 'reload schema';
