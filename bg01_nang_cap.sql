-- ═══════════════════════════════════════════════════════════════════
-- BG01 – AI SOẠN ĐƠN & BÁO GIÁ TỪ TIN ZALO (anh Tâm duyệt 13/11/2026)
-- Chỉ THÊM: 1 bảng nhật ký + 3 hàm. Không sửa bảng/hàm cũ nào.
-- Hàm máy chủ (Edge Function "doc_don") gọi 3 hàm này bằng phiên đăng nhập của người dùng.
-- Quay lại: chạy bg01_quay_lai.sql
-- ═══════════════════════════════════════════════════════════════════
begin;

-- Mỗi lần bấm "🤖 Đọc đơn" = 1 dòng. Dùng để: giới hạn lượt/ngày, đo AI đúng/sai, xem lại khi có tranh cãi.
create table if not exists ai_doc_don (
  id            bigserial primary key,
  tao_luc       timestamptz not null default now(),
  nhan_vien_id  uuid default auth.uid(),
  nguoi_dung    text,
  tin           text,                 -- tin khách đã dán (tối đa 4000 ký tự)
  so_anh        int not null default 0,
  so_ung_vien   int not null default 0, -- số món app gửi cho AI chọn
  ket_qua       jsonb,                -- AI trả về: dong[], ten_khach, ghi_chu
  loi           text,
  token_vao     int,
  token_ra      int,
  so_dong_ai    int,                  -- số món AI đọc ra
  so_dong_dung  int,                  -- số món người dùng giữ nguyên (đúng món, đúng quy cách, đúng số lượng)
  so_dong_sua   int,                  -- số món phải sửa tay / bỏ / thêm
  da_dung       boolean not null default false  -- đã bấm "Thêm vào đơn"
);
create index if not exists ai_doc_don_ngay on ai_doc_don (tao_luc);
alter table ai_doc_don enable row level security;
drop policy if exists xem on ai_doc_don;
create policy xem on ai_doc_don for select using (la_chu() or nhan_vien_id = auth.uid());
grant select on ai_doc_don to authenticated;

-- 1. Bắt đầu 1 lượt: kiểm tra đăng nhập + giới hạn 300 lượt/ngày (cả tiệm), ghi dòng nhật ký
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

-- 2. Kết thúc lượt: lưu kết quả / lỗi + số token (để tính tiền)
create or replace function ai_ket_thuc(p_id bigint, p_ket_qua jsonb, p_loi text, p_token_vao int, p_token_ra int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _bat_buoc_nhan_vien();
  update ai_doc_don set ket_qua = p_ket_qua, loi = left(p_loi, 1000), token_vao = p_token_vao, token_ra = p_token_ra,
         so_dong_ai = case when jsonb_typeof(p_ket_qua->'dong') = 'array' then jsonb_array_length(p_ket_qua->'dong') end
   where id = p_id and nhan_vien_id = auth.uid();
end $$;

-- 3. Người dùng bấm "Thêm vào đơn": ghi bao nhiêu món AI đúng, bao nhiêu phải sửa
create or replace function ai_ghi_ket_qua(p_id bigint, p_dung int, p_sua int) returns void
language plpgsql security definer set search_path = public as $$
begin
  perform _bat_buoc_nhan_vien();
  update ai_doc_don set so_dong_dung = greatest(coalesce(p_dung, 0), 0), so_dong_sua = greatest(coalesce(p_sua, 0), 0), da_dung = true
   where id = p_id and (nhan_vien_id = auth.uid() or la_chu());
end $$;

revoke execute on function ai_bat_dau(text, int, int), ai_ket_thuc(bigint, jsonb, text, int, int), ai_ghi_ket_qua(bigint, int, int) from public, anon;
grant execute on function ai_bat_dau(text, int, int), ai_ket_thuc(bigint, jsonb, text, int, int), ai_ghi_ket_qua(bigint, int, int) to authenticated;

commit;
notify pgrst, 'reload schema';
