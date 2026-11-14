-- ═══════════════════════════════════════════════════════════════════
-- PQ03 – NHÂN VIÊN THÊM HÀNG MỚI / NHÀ CUNG CẤP MỚI (anh Tâm duyệt 14/11/2026)
-- • 2 quyền mới (chủ bật cho từng người): them_hang, them_ncc
-- • nv_them_hang: CHỈ tạo món mới (tên, đơn vị, danh mục, bảng giá) – không sửa món cũ, không giá vốn, không ngừng bán
-- • Giá do nhân viên ghi vào bảng giá (thêm món, điền giá đầu, đổi giá) → đánh dấu "chờ chủ duyệt" (vẫn bán được ngay);
--   chủ bấm Duyệt hoặc tự sửa giá → hết dấu. Nhập liệu bằng SQL Editor (không đăng nhập) không bị đánh dấu.
-- • nv_luu_ncc: thêm NCC / sửa thông tin liên hệ NCC. KHÔNG được ghi ngân hàng, số tài khoản, QR, ngừng hợp tác
--   (chống đổi số TK để chuyển tiền nhầm chỗ) – phần đó chỉ chủ.
-- Quay lại: pq03_quay_lai.sql
-- ═══════════════════════════════════════════════════════════════════
begin;

-- ── Giá chờ duyệt ──
alter table bang_gia add column if not exists cho_duyet boolean not null default false;
create or replace function _danh_dau_gia_nv() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if auth.uid() is null then return new; end if;                       -- SQL Editor / hệ thống: giữ nguyên
  if la_chu() then new.cho_duyet := false; return new; end if;         -- chủ đụng vào giá = đã duyệt
  if tg_op = 'INSERT' or new.gia_ban is distinct from old.gia_ban or new.quy_cach is distinct from old.quy_cach
     or new.so_luong_quy_doi is distinct from old.so_luong_quy_doi or (new.dang_ap_dung and not old.dang_ap_dung) then
    new.cho_duyet := true;
  end if;
  return new;
end $$;
revoke execute on function _danh_dau_gia_nv() from public, anon;
drop trigger if exists trg_danh_dau_gia_nv on bang_gia;
create trigger trg_danh_dau_gia_nv before insert or update on bang_gia for each row execute function _danh_dau_gia_nv();

create or replace function duyet_gia(p_hang text) returns int
language plpgsql security definer set search_path = public as $$
declare v_n int;
begin
  perform _bat_buoc_chu();
  update bang_gia set cho_duyet = false where hang_hoa_id = p_hang and cho_duyet;
  get diagnostics v_n = row_count; return v_n;
end $$;
revoke execute on function duyet_gia(text) from public, anon;
grant execute on function duyet_gia(text) to authenticated;

-- ── NV thêm mặt hàng mới ──
create or replace function nv_them_hang(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ten text := nullif(trim(p->>'ten'), ''); v_dm int; v_id text; v_g jsonb; v_n int := 0;
begin
  perform _bat_buoc_nhan_vien(); perform _can_quyen('them_hang');
  if v_ten is null then raise exception 'Chưa nhập tên hàng'; end if;
  if exists (select 1 from hang_hoa where lower(trim(ten)) = lower(v_ten)) then raise exception 'Đã có mặt hàng tên "%"', v_ten; end if;
  if nullif(trim(p->>'danh_muc'), '') is not null then
    insert into danh_muc (ten) values (trim(p->>'danh_muc')) on conflict (ten) do nothing;
    select id into v_dm from danh_muc where ten = trim(p->>'danh_muc');
  end if;
  insert into hang_hoa (ten, don_vi, danh_muc_id, ghi_chu)
  values (v_ten, coalesce(nullif(trim(p->>'don_vi'), ''), 'cái'), v_dm, 'NV ' || _ten_nguoi_dung() || ' thêm ' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'DD/MM/YYYY'))
  returning id into v_id;
  if jsonb_typeof(p->'bang_gia') = 'array' then
    for v_g in select * from jsonb_array_elements(p->'bang_gia') loop
      continue when nullif(trim(v_g->>'quy_cach'), '') is null or coalesce(_tien(v_g->>'gia_ban'), 0) <= 0;
      if coalesce(nullif(trim(v_g->>'so_luong_quy_doi'), '')::numeric, 1) <= 0 then raise exception 'Số đơn vị của quy cách không hợp lệ'; end if;
      insert into bang_gia (hang_hoa_id, quy_cach, so_luong_quy_doi, gia_ban, ghi_chu)
      values (v_id, trim(v_g->>'quy_cach'), coalesce(nullif(trim(v_g->>'so_luong_quy_doi'), '')::numeric, 1), _tien(v_g->>'gia_ban'),
              'NV ' || _ten_nguoi_dung() || ' nhập ' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'DD/MM/YYYY'));
      v_n := v_n + 1;
    end loop;
  end if;
  return jsonb_build_object('id', v_id, 'so_gia', v_n);
end $$;
revoke execute on function nv_them_hang(jsonb) from public, anon;
grant execute on function nv_them_hang(jsonb) to authenticated;

-- ── NV thêm / sửa nhà cung cấp (không đụng ngân hàng) ──
create or replace function nv_luu_ncc(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id text := nullif(trim(p->>'id'), ''); v_ten text := nullif(trim(p->>'ten'), '');
begin
  perform _bat_buoc_nhan_vien(); perform _can_quyen('them_ncc');
  if v_ten is null then raise exception 'Chưa nhập tên nhà cung cấp'; end if;
  if p ?| array['bin', 'ten_ngan_hang', 'so_tk', 'ten_tk', 'anh_qr', 'dang_hop_tac'] then
    raise exception 'Ngân hàng, số tài khoản, QR, ngừng hợp tác: chỉ chủ được ghi'; end if;
  if v_id is null then
    insert into nha_cung_cap (ten, dia_chi, sdt, nguoi_lien_he, sdt_nv, zalo_nv, lich_giao, ghi_chu, dieu_kien_no, han_no_ngay)
    values (v_ten, nullif(trim(p->>'dia_chi'), ''), nullif(trim(p->>'sdt'), ''), nullif(trim(p->>'nguoi_lien_he'), ''), nullif(trim(p->>'sdt_nv'), ''),
            nullif(trim(p->>'zalo_nv'), ''), nullif(trim(p->>'lich_giao'), ''),
            trim(both ' ' from coalesce(nullif(trim(p->>'ghi_chu'), '') || ' · ', '') || 'NV ' || _ten_nguoi_dung() || ' thêm ' || to_char(now() at time zone 'Asia/Ho_Chi_Minh', 'DD/MM/YYYY')),
            nullif(trim(p->>'dieu_kien_no'), ''), least(greatest(nullif(trim(p->>'han_no_ngay'), '')::int, 0), 365))
    returning id into v_id;
  else
    update nha_cung_cap set ten = v_ten, dia_chi = nullif(trim(p->>'dia_chi'), ''), sdt = nullif(trim(p->>'sdt'), ''),
      nguoi_lien_he = nullif(trim(p->>'nguoi_lien_he'), ''), sdt_nv = nullif(trim(p->>'sdt_nv'), ''), zalo_nv = nullif(trim(p->>'zalo_nv'), ''),
      lich_giao = nullif(trim(p->>'lich_giao'), ''), ghi_chu = nullif(trim(p->>'ghi_chu'), ''), dieu_kien_no = nullif(trim(p->>'dieu_kien_no'), ''),
      han_no_ngay = least(greatest(nullif(trim(p->>'han_no_ngay'), '')::int, 0), 365)
    where id = v_id;
    if not found then raise exception 'Không tìm thấy nhà cung cấp %', v_id; end if;
  end if;
  return jsonb_build_object('id', v_id);
end $$;
revoke execute on function nv_luu_ncc(jsonb) from public, anon;
grant execute on function nv_luu_ncc(jsonb) to authenticated;

commit;
notify pgrst, 'reload schema';
