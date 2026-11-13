-- QUAY LẠI BG01: xoá bảng nhật ký AI + 3 hàm. (Xoá luôn Edge Function "doc_don" trong Supabase → Edge Functions.)
begin;
drop function if exists ai_bat_dau(text, int, int), ai_ket_thuc(bigint, jsonb, text, int, int), ai_ghi_ket_qua(bigint, int, int);
drop table if exists ai_doc_don;
commit;
notify pgrst, 'reload schema';
