-- QUAY LẠI DT01: xoá bảng mã NCC + hàm lưu mã, trả ai_bat_dau về bản BG01, bỏ cột viec. (Xoá luôn Edge Function "doc_toa".)
begin;
drop function if exists luu_ma_hang_ncc(text, jsonb);
drop table if exists ma_hang_ncc;
drop function if exists ai_bat_dau(text, int, int, text);
create or replace function ai_bat_dau(p_tin text, p_so_anh int, p_so_ung_vien int) returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_n int;
begin
  perform _bat_buoc_nhan_vien();
  select count(*) into v_n from ai_doc_don
   where tao_luc >= (date_trunc('day', now() at time zone 'Asia/Ho_Chi_Minh') at time zone 'Asia/Ho_Chi_Minh');
  if v_n >= 300 then raise exception 'Hết lượt AI hôm nay (300 lượt/ngày) – lên đơn tay giúp em'; end if;
  insert into ai_doc_don (nguoi_dung, tin, so_anh, so_ung_vien)
  values (_ten_nguoi_dung(), left(p_tin, 4000), coalesce(p_so_anh, 0), coalesce(p_so_ung_vien, 0))
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function ai_bat_dau(text, int, int) from public, anon;
grant execute on function ai_bat_dau(text, int, int) to authenticated;
alter table ai_doc_don drop column if exists viec;
commit;
notify pgrst, 'reload schema';
