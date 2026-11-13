-- ═══════════════════════════════════════════════════════════════════
-- DT01 – AI ĐỌC TOA NCC BẰNG CLAUDE (anh Tâm duyệt 13/11/2026)
-- • Nhật ký AI (ai_doc_don) thêm cột "viec": doc_don | doc_toa  → Chốt sổ tách 2 dòng
-- • ai_bat_dau thêm tham số p_viec; đọc toa cần quyền "Nhập toa NCC"
-- • Bảng ma_hang_ncc: nhớ "mã SP của NCC" = món nào trong app (sửa 1 lần, lần sau đúng luôn)
-- Quay lại: dt01_quay_lai.sql
-- ═══════════════════════════════════════════════════════════════════
begin;

alter table ai_doc_don add column if not exists viec text not null default 'doc_don';

drop function if exists ai_bat_dau(text, int, int);
create or replace function ai_bat_dau(p_tin text, p_so_anh int, p_so_ung_vien int, p_viec text default 'doc_don') returns bigint
language plpgsql security definer set search_path = public as $$
declare v_id bigint; v_n int;
begin
  perform _bat_buoc_nhan_vien();
  if p_viec not in ('doc_don', 'doc_toa') then raise exception 'Việc AI không hợp lệ: %', p_viec; end if;
  if p_viec = 'doc_toa' then perform _can_quyen('nhap_toa'); end if;
  select count(*) into v_n from ai_doc_don
   where tao_luc >= (date_trunc('day', now() at time zone 'Asia/Ho_Chi_Minh') at time zone 'Asia/Ho_Chi_Minh');
  if v_n >= 300 then raise exception 'Hết lượt AI hôm nay (300 lượt/ngày) – nhập tay giúp em'; end if;
  insert into ai_doc_don (nguoi_dung, tin, so_anh, so_ung_vien, viec)
  values (_ten_nguoi_dung(), left(p_tin, 4000), coalesce(p_so_anh, 0), coalesce(p_so_ung_vien, 0), p_viec)
  returning id into v_id;
  return v_id;
end $$;
revoke execute on function ai_bat_dau(text, int, int, text) from public, anon;
grant execute on function ai_bat_dau(text, int, int, text) to authenticated;

-- Mã SP in trên toa của từng NCC (vd TPNDTOPET02) → món trong app
create table if not exists ma_hang_ncc (
  ncc_id      text not null references nha_cung_cap(id) on delete cascade,
  ma          text not null,
  hang_hoa_id text not null references hang_hoa(id) on delete cascade,
  nguoi       text,
  sua_luc     timestamptz not null default now(),
  primary key (ncc_id, ma)
);
alter table ma_hang_ncc enable row level security;
drop policy if exists xem on ma_hang_ncc;
create policy xem on ma_hang_ncc for select using (la_nhan_vien());
grant select on ma_hang_ncc to authenticated;

-- Lưu toa xong: ghi / sửa các cặp mã → món (người có quyền nhập toa)
create or replace function luu_ma_hang_ncc(p_ncc text, p_ds jsonb) returns int
language plpgsql security definer set search_path = public as $$
declare v_n int := 0; v jsonb;
begin
  perform _bat_buoc_nhan_vien(); perform _can_quyen('nhap_toa');
  if jsonb_typeof(p_ds) is distinct from 'array' then return 0; end if;
  for v in select * from jsonb_array_elements(p_ds) loop
    if coalesce(trim(v->>'ma'), '') = '' or not exists (select 1 from hang_hoa where id = v->>'hang_hoa_id') then continue; end if;
    insert into ma_hang_ncc (ncc_id, ma, hang_hoa_id, nguoi) values (p_ncc, upper(trim(v->>'ma')), v->>'hang_hoa_id', _ten_nguoi_dung())
    on conflict (ncc_id, ma) do update set hang_hoa_id = excluded.hang_hoa_id, nguoi = excluded.nguoi, sua_luc = now()
      where ma_hang_ncc.hang_hoa_id is distinct from excluded.hang_hoa_id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;
revoke execute on function luu_ma_hang_ncc(text, jsonb) from public, anon;
grant execute on function luu_ma_hang_ncc(text, jsonb) to authenticated;

commit;
notify pgrst, 'reload schema';
