-- ═══════════════════════════════════════════════════════════════════════
-- TH01 – TRẢ HÀNG & ĐỔI THƯỞNG NẮP  (biên bản TH01, anh Tâm duyệt 12/11/2026)
-- Chạy 1 lần trong Supabase → SQL Editor. Chạy lại lần 2 cũng không sao.
-- Quay lại bản cũ: chạy file th01_quay_lai.sql
-- ═══════════════════════════════════════════════════════════════════════
begin;

-- ── 1. CỘT MỚI TRÊN ĐƠN HÀNG ─────────────────────────────────────────────
-- Công thức 1 đơn:  hàng = tiền hàng − chiết khấu
--   còn = hàng − trả hàng − đổi thưởng − khoản treo trừ vào đơn
--   còn ≥ 0 → tong_cong = còn (khách phải trả)
--   còn < 0 → phần dư trừ nợ cũ trước (tien_can_tru), còn lại trả tiền mặt cho khách (tien_tra_lai)
alter table don_hang add column if not exists tru_tra_hang   bigint not null default 0;  -- tiền hàng khách trả lại (đã trừ)
alter table don_hang add column if not exists tru_doi_thuong bigint not null default 0;  -- tiền thưởng nắp trừ vào đơn
alter table don_hang add column if not exists tru_khac       bigint not null default 0;  -- khoản mình nợ khách từ trước, trừ vào đơn này
alter table don_hang add column if not exists tien_can_tru   bigint not null default 0;  -- phần dư đã trừ vào nợ cũ
alter table don_hang add column if not exists tien_tra_lai   bigint not null default 0;  -- phần dư trả tiền mặt cho khách
alter table don_hang add column if not exists dt_thuan       bigint;                     -- doanh thu thuần = hàng − trả hàng (báo cáo)

-- Thanh toán loại "Cấn trừ": tiền trả hàng/thưởng dư ra, trừ vào đơn nợ cũ (không phải tiền thật vào két)
alter table thanh_toan drop constraint if exists thanh_toan_hinh_thuc_check;
alter table thanh_toan add constraint thanh_toan_hinh_thuc_check check (hinh_thuc in ('Tiền mặt', 'Chuyển khoản', 'Cấn trừ'));
alter table thanh_toan add column if not exists tu_don text;   -- cấn trừ phát sinh từ đơn nào (để huỷ đơn thì gỡ)

-- ── 2. BẢNG MỚI ──────────────────────────────────────────────────────────
create sequence if not exists seq_tra_hang;
create table if not exists tra_hang (
  id               text primary key default ('TH' || lpad(nextval('seq_tra_hang')::text, 6, '0')),
  don_hang_id      text references don_hang(id),
  khach_hang_id    text not null references khach_hang(id),
  hang_hoa_id      text not null references hang_hoa(id),
  ten_hang         text not null,
  quy_cach         text not null,
  so_luong_quy_doi numeric not null default 1 check (so_luong_quy_doi > 0),
  so_luong         numeric not null check (so_luong > 0),
  don_gia          bigint not null check (don_gia >= 0),
  thanh_tien       bigint not null,
  ly_do            text,
  hang_tot         boolean not null default true,        -- true = còn bán được → cộng lại tồn kho
  trang_thai       text not null default 'da_tru'
                   check (trang_thai in ('da_tru', 'cho_kiem_tra', 'khong_nhan', 'da_nhan_sau', 'doi_lay_lai', 'huy')),
  ngay             timestamptz not null default now(),
  nguoi_tao        text,
  nhan_vien_id     uuid,
  xu_ly_luc        timestamptz,
  nguoi_xu_ly      text
);
create index if not exists tra_hang_kh on tra_hang (khach_hang_id, hang_hoa_id);

create sequence if not exists seq_chuong_trinh;
create table if not exists chuong_trinh_thuong (
  id        text primary key default ('CT' || lpad(nextval('seq_chuong_trinh')::text, 4, '0')),
  ten       text not null,
  ncc_id    text references nha_cung_cap(id),
  -- muc: [{"ten":"10k","loai":"tien","gia_tri":10000} | {"ten":"1 lon","loai":"hang","hang_hoa_id":"HH..","so_luong":1}]
  -- so_luong của mức "hang" tính theo đơn vị nhỏ nhất của món (lon/chai)
  muc       jsonb not null default '[]'::jsonb,
  dang_chay boolean not null default true,
  ghi_chu   text,
  tao_luc   timestamptz not null default now()
);

create sequence if not exists seq_doi_nap;
create table if not exists doi_nap_ncc (            -- 1 lần mang nắp đổi với NCC
  id           text primary key default ('DN' || lpad(nextval('seq_doi_nap')::text, 5, '0')),
  chuong_trinh_id text not null references chuong_trinh_thuong(id),
  ncc_id       text references nha_cung_cap(id),
  so_nap       int not null,
  tong_tien    bigint not null default 0,          -- tiền NCC trả lại (trừ nợ hoặc tiền mặt)
  tong_hang    numeric not null default 0,         -- số lon/chai NCC trả lại (cộng tồn)
  cach         text not null check (cach in ('tru_no', 'tien_mat')),
  tra_ncc_id   bigint,
  ngay         timestamptz not null default now(),
  nguoi_tao    text
);

create table if not exists doi_thuong (
  id              bigint generated always as identity primary key,
  don_hang_id     text references don_hang(id),
  khach_hang_id   text not null references khach_hang(id),
  chuong_trinh_id text not null references chuong_trinh_thuong(id),
  muc_ten         text not null,
  loai            text not null check (loai in ('tien', 'hang')),
  gia_tri         bigint not null default 0,        -- tiền thưởng 1 nắp (loại tiền)
  hang_hoa_id     text references hang_hoa(id),     -- món thưởng (loại hàng)
  so_luong_hang   numeric not null default 0,       -- số lon thưởng 1 nắp
  so_nap          int not null check (so_nap > 0),
  da_tra_khach    boolean not null default true,    -- false = chưa trả khách (có việc treo nhắc)
  doi_nap_id      text references doi_nap_ncc(id),  -- null = nắp còn giữ, chưa đổi với NCC
  trang_thai      text not null default 'hoan_tat' check (trang_thai in ('hoan_tat', 'huy')),
  ngay            timestamptz not null default now(),
  nguoi_tao       text,
  nhan_vien_id    uuid
);
create index if not exists doi_thuong_ct on doi_thuong (chuong_trinh_id) where doi_nap_id is null;

create table if not exists viec_treo_khach (
  id            bigint generated always as identity primary key,
  khach_hang_id text not null references khach_hang(id),
  loai          text not null check (loai in ('no_thuong_tien', 'no_thuong_hang', 'kh_lay_lai', 'cho_kiem_tra', 'no_tien')),
  noi_dung      text not null,                     -- câu nhắc hiện cho người bán
  so_tien       bigint not null default 0,         -- loại tiền: số tiền mình nợ khách
  hang_hoa_id   text references hang_hoa(id),      -- loại hàng: món mình nợ khách
  so_luong      numeric not null default 0,        -- số lượng theo đơn vị nhỏ nhất
  tra_hang_id   text references tra_hang(id),
  doi_thuong_id bigint references doi_thuong(id),
  don_hang_id   text references don_hang(id),      -- đơn phát sinh
  trang_thai    text not null default 'mo' check (trang_thai in ('mo', 'xong', 'huy')),
  ket_qua       text,
  tien_mat_chi  bigint not null default 0,         -- tiền mặt đưa khách khi xử lý (chốt sổ trừ két)
  tao_luc       timestamptz not null default now(),
  nguoi_tao     text,
  xu_ly_luc     timestamptz,
  nguoi_xu_ly   text
);
create index if not exists viec_treo_mo on viec_treo_khach (khach_hang_id) where trang_thai = 'mo';

-- Quyền: ai đăng nhập (nhân viên đang hoạt động) được XEM; GHI chỉ qua các hàm bên dưới / chủ
do $$ declare t text; begin
  foreach t in array array['tra_hang', 'chuong_trinh_thuong', 'doi_nap_ncc', 'doi_thuong', 'viec_treo_khach'] loop
    execute format('alter table %I enable row level security', t);
    execute format('drop policy if exists xem on %I', t);
    execute format('drop policy if exists chu_ghi on %I', t);
    execute format('create policy xem on %I for select using (la_nhan_vien())', t);
    execute format('create policy chu_ghi on %I for all using (la_chu()) with check (la_chu())', t);
    execute format('grant select, insert, update, delete on %I to authenticated', t);
  end loop;
end $$;
grant usage on sequence seq_tra_hang, seq_chuong_trinh, seq_doi_nap to authenticated;

-- ── 3. HÀM PHỤ ───────────────────────────────────────────────────────────
-- Số lượng (đơn vị nhỏ nhất) khách còn được trả của 1 món = đã mua − đã trả. Khách lẻ = 0 (không kiểm được).
create or replace function _con_duoc_tra(p_kh text, p_hh text) returns numeric
language sql stable security definer set search_path = public as $$
  select case when p_kh = 'KHLE' then 0 else greatest(
    coalesce((select sum(c.so_luong * c.so_luong_quy_doi) from don_hang_ct c join don_hang d on d.id = c.don_hang_id
               where d.khach_hang_id = p_kh and c.hang_hoa_id = p_hh and d.trang_thai = 'hoan_tat'), 0)
  - coalesce((select sum(so_luong * so_luong_quy_doi) from tra_hang
               where khach_hang_id = p_kh and hang_hoa_id = p_hh and trang_thai in ('da_tru', 'da_nhan_sau', 'doi_lay_lai')), 0), 0) end
$$;

-- Giá trả hàng gợi ý + số còn được trả (app gọi khi thêm dòng trả hàng)
create or replace function gia_tra_hang(p_kh text, p_hh text, p_qc text default null) returns jsonb
language plpgsql stable security definer set search_path = public as $$
declare v_gia bigint; v_qd numeric; v_ngay timestamptz; v_hh hang_hoa%rowtype; v_qc text;
begin
  perform _bat_buoc_nhan_vien();
  select * into v_hh from hang_hoa where id = p_hh;
  if not found then raise exception 'Không tìm thấy mặt hàng %', p_hh; end if;
  v_qc := coalesce(nullif(trim(p_qc), ''), v_hh.don_vi);
  -- 1) giá lần gần nhất khách này mua đúng quy cách đó
  select c.don_gia - c.giam_gia, c.so_luong_quy_doi, d.ngay into v_gia, v_qd, v_ngay
    from don_hang_ct c join don_hang d on d.id = c.don_hang_id
   where d.khach_hang_id = p_kh and p_kh <> 'KHLE' and c.hang_hoa_id = p_hh and lower(c.quy_cach) = lower(v_qc) and d.trang_thai = 'hoan_tat'
   order by d.ngay desc limit 1;
  if v_gia is null then   -- 2) chưa mua → giá bán hiện tại
    select gia_ban, so_luong_quy_doi into v_gia, v_qd from bang_gia
     where hang_hoa_id = p_hh and lower(quy_cach) = lower(v_qc) and dang_ap_dung limit 1;
  end if;
  return jsonb_build_object('gia', v_gia, 'quy_doi', coalesce(v_qd, 1), 'quy_cach', v_qc,
    'mua_luc', v_ngay, 'con_duoc_tra', _con_duoc_tra(p_kh, p_hh), 'don_vi', v_hh.don_vi);
end $$;

-- Trừ phần dư vào nợ cũ của khách (đơn cũ nhất trước). Trả về số đã trừ.
create or replace function _can_tru_no(p_kh text, p_tien bigint, p_tu text, p_ghi_chu text) returns bigint
language plpgsql security definer set search_path = public as $$
declare r record; v_con bigint := p_tien; v_tru bigint;
begin
  if p_kh = 'KHLE' or p_tien <= 0 then return 0; end if;
  for r in select id, con_no from v_don_hang where khach_hang_id = p_kh and con_no > 0 and id is distinct from p_tu order by ngay, id loop
    exit when v_con <= 0;
    v_tru := least(v_con, r.con_no);
    insert into thanh_toan (khach_hang_id, don_hang_id, so_tien, hinh_thuc, nhan_vien_id, nguoi_thu, ghi_chu, tu_don)
    values (p_kh, r.id, v_tru, 'Cấn trừ', auth.uid(), _ten_nguoi_dung(), p_ghi_chu, p_tu);
    v_con := v_con - v_tru;
  end loop;
  return p_tien - v_con;
end $$;

-- ── 4. TẠO ĐƠN (thêm trả hàng, đổi thưởng, trừ khoản treo) ───────────────
create or replace function public.tao_don_hang(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $function$
declare
  v_kh    text := nullif(trim(p->>'khach_hang_id'), '');
  v_ht    text := coalesce(nullif(p->>'hinh_thuc', ''), 'Ghi nợ');
  v_ck    bigint := coalesce(_tien(p->>'chiet_khau'), 0);
  v_nv    text := _ten_nguoi_dung();
  v_ten_moi text := nullif(trim(p#>>'{khach_moi,ten}'), '');
  v_sdt_moi text := nullif(regexp_replace(coalesce(p#>>'{khach_moi,sdt}', ''), '\D', '', 'g'), '');
  v_dh    text;
  v_it    jsonb;
  v_hh    hang_hoa%rowtype;
  v_bg    bang_gia%rowtype;
  v_co_gia boolean;
  v_qc    text;
  v_sl    numeric;
  v_qd    numeric;
  v_gia   bigint;
  v_giam  bigint;
  v_tt    bigint;
  v_tong  bigint := 0;
  v_stt   int := 0;
  v_cong  bigint;
  v_ma    text := nullif(trim(p->>'ma_phieu'), '');
  v_giao  boolean := coalesce((p->>'can_giao')::boolean, true);
  -- TH01
  v_tra   bigint := 0;   -- tổng tiền trả hàng được trừ
  v_thg   bigint := 0;   -- tổng tiền thưởng trừ vào đơn
  v_treo  bigint := 0;   -- khoản treo (mình nợ khách) trừ vào đơn
  v_con   bigint;        -- còn lại sau khi trừ (có thể âm)
  v_du    bigint := 0;
  v_cantru bigint := 0;
  v_ctl   chuong_trinh_thuong%rowtype;
  v_muc   jsonb;
  v_nap   int;
  v_duoc  numeric;      -- số còn được trả (đơn vị nhỏ nhất)
  v_sl1   numeric;      -- phần được trừ (theo quy cách)
  v_sl2   numeric;      -- phần chờ kiểm tra
  v_th_id text;
  v_dt_id bigint;
  v_cho   int := 0;     -- số dòng chờ chủ kiểm tra
  v_vt    viec_treo_khach%rowtype;
  v_tt_tra text;
begin
  perform _bat_buoc_nhan_vien();
  if v_ma is not null then
    perform pg_advisory_xact_lock(hashtext('don:' || v_ma));
    select jsonb_build_object('id', id, 'khach_hang_id', khach_hang_id, 'tong_cong', tong_cong, 'hinh_thuc', hinh_thuc,
                              'tien_tra_lai', tien_tra_lai, 'tien_can_tru', tien_can_tru, 'trung', true)
      into v_it from don_hang where ma_phieu = v_ma;
    if v_it is not null then return v_it; end if;
  end if;
  if v_ht not in ('Tiền mặt', 'Chuyển khoản', 'Ghi nợ') then
    raise exception 'Hình thức thanh toán không hợp lệ: %', v_ht;
  end if;
  if coalesce(jsonb_array_length(case when jsonb_typeof(p->'items') = 'array' then p->'items' end), 0)
   + coalesce(jsonb_array_length(case when jsonb_typeof(p->'tra_hang') = 'array' then p->'tra_hang' end), 0)
   + coalesce(jsonb_array_length(case when jsonb_typeof(p->'doi_thuong') = 'array' then p->'doi_thuong' end), 0)
   + coalesce(jsonb_array_length(case when jsonb_typeof(p->'tru_treo') = 'array' then p->'tru_treo' end), 0) = 0 then
    raise exception 'Đơn chưa có mặt hàng nào';
  end if;

  if v_kh is null and v_ten_moi is not null then
    select id into v_kh from khach_hang
     where (v_sdt_moi is not null and regexp_replace(coalesce(sdt, ''), '\D', '', 'g') = v_sdt_moi)
        or lower(trim(ten)) = lower(v_ten_moi)
     order by tao_luc limit 1;
    if v_kh is null then
      insert into khach_hang (ten, sdt) values (v_ten_moi, nullif(trim(p#>>'{khach_moi,sdt}'), ''))
      returning id into v_kh;
    end if;
  end if;
  v_kh := coalesce(v_kh, 'KHLE');
  if not exists (select 1 from khach_hang where id = v_kh) then
    raise exception 'Không tìm thấy khách hàng %', v_kh;
  end if;

  insert into don_hang (khach_hang_id, nhan_vien_id, nguoi_tao, kenh, hinh_thuc, ghi_chu, ma_phieu, da_giao, giao_luc)
  values (v_kh, auth.uid(), v_nv, coalesce(nullif(p->>'kenh', ''), 'Zalo'), v_ht, nullif(trim(p->>'ghi_chu'), ''), v_ma,
          not v_giao, case when v_giao then null else now() end)
  returning id into v_dh;

  -- (a) Hàng bán – như cũ
  for v_it in select * from jsonb_array_elements(coalesce(p->'items', '[]'::jsonb)) loop
    v_stt := v_stt + 1;
    select * into v_hh from hang_hoa where id = v_it->>'hang_hoa_id';
    if not found then raise exception 'Không tìm thấy mặt hàng %', v_it->>'hang_hoa_id'; end if;
    v_qc := coalesce(nullif(trim(v_it->>'quy_cach'), ''), v_hh.don_vi);
    v_sl := nullif(trim(v_it->>'so_luong'), '')::numeric;
    if v_sl is null or v_sl <= 0 then raise exception 'Số lượng không hợp lệ: %', v_hh.ten; end if;
    select * into v_bg from bang_gia
     where hang_hoa_id = v_hh.id and lower(quy_cach) = lower(v_qc) and dang_ap_dung limit 1;
    v_co_gia := found;
    v_qd   := case when v_co_gia then v_bg.so_luong_quy_doi
                   else coalesce(nullif(trim(v_it->>'so_luong_quy_doi'), '')::numeric, 1) end;
    v_gia  := coalesce(_tien(v_it->>'don_gia'), case when v_co_gia then v_bg.gia_ban end);
    if v_gia is null or v_gia <= 0 then
      raise exception '"%" chưa có giá cho quy cách "%"', v_hh.ten, v_qc;
    end if;
    v_giam := least(greatest(coalesce(_tien(v_it->>'giam_gia'), 0), 0), v_gia);   -- giảm giá không âm, không quá đơn giá
    v_tt   := round(v_sl * (v_gia - v_giam));
    insert into don_hang_ct (don_hang_id, stt, hang_hoa_id, ten_hang, quy_cach, so_luong_quy_doi,
                             so_luong, don_gia, giam_gia, thanh_tien, gia_von)
    values (v_dh, v_stt, v_hh.id, v_hh.ten, v_qc, v_qd, v_sl, v_gia, v_giam, v_tt, v_hh.gia_von);
    v_tong := v_tong + v_tt;
    if not v_co_gia and coalesce((v_it->>'luu_gia')::boolean, false) then
      insert into bang_gia (hang_hoa_id, quy_cach, so_luong_quy_doi, gia_ban)
      values (v_hh.id, v_qc, v_qd, v_gia) on conflict do nothing;
    end if;
    update hang_hoa set ton_kho = ton_kho - v_sl * v_qd where id = v_hh.id and ton_kho is not null;
  end loop;

  -- (b) TRẢ HÀNG – chỉ trừ tiền phần khách THẬT SỰ đã mua; phần còn lại chờ chủ kiểm tra
  for v_it in select * from jsonb_array_elements(coalesce(p->'tra_hang', '[]'::jsonb)) loop
    select * into v_hh from hang_hoa where id = v_it->>'hang_hoa_id';
    if not found then raise exception 'Không tìm thấy mặt hàng trả %', v_it->>'hang_hoa_id'; end if;
    v_qc := coalesce(nullif(trim(v_it->>'quy_cach'), ''), v_hh.don_vi);
    v_sl := nullif(trim(v_it->>'so_luong'), '')::numeric;
    if v_sl is null or v_sl <= 0 then raise exception 'Số lượng trả không hợp lệ: %', v_hh.ten; end if;
    v_qd := coalesce(nullif(trim(v_it->>'so_luong_quy_doi'), '')::numeric,
                     (select so_luong_quy_doi from bang_gia where hang_hoa_id = v_hh.id and lower(quy_cach) = lower(v_qc) and dang_ap_dung limit 1), 1);
    if v_qd <= 0 then v_qd := 1; end if;
    v_gia := _tien(v_it->>'don_gia');
    if v_gia is null or v_gia < 0 then raise exception 'Giá trả hàng không hợp lệ: %', v_hh.ten; end if;

    -- Khách muốn đổi lấy hàng mới sau → không trừ tiền, ghi việc treo "khách lấy lại"
    if coalesce((v_it->>'doi_lay_lai')::boolean, false) then
      v_duoc := _con_duoc_tra(v_kh, v_hh.id);
      if v_duoc < v_sl * v_qd then   -- chưa mua / trả quá → vẫn phải chờ chủ kiểm tra
        v_tt_tra := 'cho_kiem_tra';
      else
        v_tt_tra := 'doi_lay_lai';
      end if;
      insert into tra_hang (don_hang_id, khach_hang_id, hang_hoa_id, ten_hang, quy_cach, so_luong_quy_doi, so_luong, don_gia, thanh_tien,
                            ly_do, hang_tot, trang_thai, nguoi_tao, nhan_vien_id)
      values (v_dh, v_kh, v_hh.id, v_hh.ten, v_qc, v_qd, v_sl, v_gia, 0, nullif(trim(v_it->>'ly_do'), ''),
              coalesce((v_it->>'hang_tot')::boolean, true), v_tt_tra, v_nv, auth.uid())
      returning id into v_th_id;
      if v_tt_tra = 'doi_lay_lai' then
        if coalesce((v_it->>'hang_tot')::boolean, true) then
          update hang_hoa set ton_kho = ton_kho + v_sl * v_qd where id = v_hh.id and ton_kho is not null;
        end if;
        insert into viec_treo_khach (khach_hang_id, loai, noi_dung, hang_hoa_id, so_luong, tra_hang_id, don_hang_id, nguoi_tao)
        values (v_kh, 'kh_lay_lai', format('Khách đã trả %s %s %s – chờ lấy lại hàng mới', so_dep(v_sl), v_qc, v_hh.ten),
                v_hh.id, v_sl * v_qd, v_th_id, v_dh, v_nv);
      else
        v_cho := v_cho + 1;
        insert into viec_treo_khach (khach_hang_id, loai, noi_dung, hang_hoa_id, so_luong, so_tien, tra_hang_id, don_hang_id, nguoi_tao)
        values (v_kh, 'cho_kiem_tra', format('Trả %s %s %s (muốn đổi hàng mới) – %s', so_dep(v_sl), v_qc, v_hh.ten,
                case when v_kh = 'KHLE' then 'khách lẻ, chủ kiểm tra' else 'chưa mua đủ số này, chủ kiểm tra' end),
                v_hh.id, v_sl * v_qd, 0, v_th_id, v_dh, v_nv);
      end if;
      continue;
    end if;

    -- Chia: phần được trừ tiền (≤ số còn được trả) và phần chờ kiểm tra
    v_duoc := _con_duoc_tra(v_kh, v_hh.id);
    v_sl1  := least(v_sl, floor(v_duoc / v_qd * 1000) / 1000);
    if v_sl1 < 0 then v_sl1 := 0; end if;
    v_sl2  := v_sl - v_sl1;
    if v_sl1 > 0 then
      v_tt := round(v_sl1 * v_gia);
      insert into tra_hang (don_hang_id, khach_hang_id, hang_hoa_id, ten_hang, quy_cach, so_luong_quy_doi, so_luong, don_gia, thanh_tien,
                            ly_do, hang_tot, trang_thai, nguoi_tao, nhan_vien_id)
      values (v_dh, v_kh, v_hh.id, v_hh.ten, v_qc, v_qd, v_sl1, v_gia, v_tt, nullif(trim(v_it->>'ly_do'), ''),
              coalesce((v_it->>'hang_tot')::boolean, true), 'da_tru', v_nv, auth.uid());
      v_tra := v_tra + v_tt;
      if coalesce((v_it->>'hang_tot')::boolean, true) then
        update hang_hoa set ton_kho = ton_kho + v_sl1 * v_qd where id = v_hh.id and ton_kho is not null;
      end if;
    end if;
    if v_sl2 > 0 then
      v_cho := v_cho + 1;
      insert into tra_hang (don_hang_id, khach_hang_id, hang_hoa_id, ten_hang, quy_cach, so_luong_quy_doi, so_luong, don_gia, thanh_tien,
                            ly_do, hang_tot, trang_thai, nguoi_tao, nhan_vien_id)
      values (v_dh, v_kh, v_hh.id, v_hh.ten, v_qc, v_qd, v_sl2, v_gia, round(v_sl2 * v_gia), nullif(trim(v_it->>'ly_do'), ''),
              coalesce((v_it->>'hang_tot')::boolean, true), 'cho_kiem_tra', v_nv, auth.uid())
      returning id into v_th_id;
      insert into viec_treo_khach (khach_hang_id, loai, noi_dung, so_tien, hang_hoa_id, so_luong, tra_hang_id, don_hang_id, nguoi_tao)
      values (v_kh, 'cho_kiem_tra',
              format('Trả %s %s %s = %s đ – %s', so_dep(v_sl2), v_qc, v_hh.ten, so_dep(round(v_sl2 * v_gia)),
                     case when v_kh = 'KHLE' then 'khách lẻ, chủ kiểm tra'
                          when v_sl1 > 0 then 'vượt số khách đã mua, chủ kiểm tra'
                          else 'khách chưa từng mua món này, chủ kiểm tra' end),
              round(v_sl2 * v_gia), v_hh.id, v_sl2 * v_qd, v_th_id, v_dh, v_nv);
    end if;
  end loop;

  -- (c) ĐỔI THƯỞNG NẮP theo chương trình
  for v_it in select * from jsonb_array_elements(coalesce(p->'doi_thuong', '[]'::jsonb)) loop
    select * into v_ctl from chuong_trinh_thuong where id = v_it->>'chuong_trinh_id';
    if not found then raise exception 'Không tìm thấy chương trình thưởng %', v_it->>'chuong_trinh_id'; end if;
    select m into v_muc from jsonb_array_elements(v_ctl.muc) m where m->>'ten' = v_it->>'muc' limit 1;
    if v_muc is null then raise exception 'Chương trình "%" không có mức "%"', v_ctl.ten, v_it->>'muc'; end if;
    v_nap := nullif(trim(v_it->>'so_nap'), '')::int;
    if v_nap is null or v_nap <= 0 then raise exception 'Số nắp không hợp lệ'; end if;
    insert into doi_thuong (don_hang_id, khach_hang_id, chuong_trinh_id, muc_ten, loai, gia_tri, hang_hoa_id, so_luong_hang, so_nap,
                            da_tra_khach, nguoi_tao, nhan_vien_id)
    values (v_dh, v_kh, v_ctl.id, v_muc->>'ten', v_muc->>'loai', coalesce((v_muc->>'gia_tri')::bigint, 0),
            nullif(v_muc->>'hang_hoa_id', ''), coalesce((v_muc->>'so_luong')::numeric, 0), v_nap,
            not coalesce((v_it->>'chua_tra')::boolean, false), v_nv, auth.uid())
    returning id into v_dt_id;
    if coalesce((v_it->>'chua_tra')::boolean, false) then
      -- Chưa trả khách ngay → ghi việc treo để đơn sau nhắc
      if v_muc->>'loai' = 'tien' then
        insert into viec_treo_khach (khach_hang_id, loai, noi_dung, so_tien, doi_thuong_id, don_hang_id, nguoi_tao)
        values (v_kh, 'no_thuong_tien', format('Nợ khách thưởng %s × %s = %s đ (%s)', v_nap, v_muc->>'ten',
                so_dep(v_nap * (v_muc->>'gia_tri')::bigint), v_ctl.ten), v_nap * (v_muc->>'gia_tri')::bigint, v_dt_id, v_dh, v_nv);
      else
        insert into viec_treo_khach (khach_hang_id, loai, noi_dung, hang_hoa_id, so_luong, doi_thuong_id, don_hang_id, nguoi_tao)
        values (v_kh, 'no_thuong_hang', format('Nợ khách %s × %s (%s)', v_nap, v_muc->>'ten', v_ctl.ten),
                nullif(v_muc->>'hang_hoa_id', ''), v_nap * coalesce((v_muc->>'so_luong')::numeric, 0), v_dt_id, v_dh, v_nv);
      end if;
    elsif v_muc->>'loai' = 'tien' then
      v_thg := v_thg + v_nap * (v_muc->>'gia_tri')::bigint;
    else
      -- Thưởng lon: đưa khách hàng thật → trừ tồn kho, 0đ
      update hang_hoa set ton_kho = ton_kho - v_nap * coalesce((v_muc->>'so_luong')::numeric, 0)
       where id = v_muc->>'hang_hoa_id' and ton_kho is not null;
    end if;
  end loop;

  -- (d) Khoản mình nợ khách từ trước (thưởng chưa trả, trả hàng chủ đã nhận) → trừ vào đơn này. Chỉ chủ.
  for v_it in select * from jsonb_array_elements(coalesce(p->'tru_treo', '[]'::jsonb)) loop
    perform _bat_buoc_chu();
    select * into v_vt from viec_treo_khach where id = (v_it #>> '{}')::bigint for update;
    if not found or v_vt.trang_thai <> 'mo' or v_vt.khach_hang_id <> v_kh or v_vt.loai not in ('no_thuong_tien', 'no_tien') then
      raise exception 'Khoản treo % không trừ được vào đơn này', v_it #>> '{}';
    end if;
    v_treo := v_treo + v_vt.so_tien;
    update viec_treo_khach set trang_thai = 'xong', ket_qua = 'Trừ vào đơn ' || v_dh, xu_ly_luc = now(), nguoi_xu_ly = v_nv where id = v_vt.id;
    if v_vt.doi_thuong_id is not null then update doi_thuong set da_tra_khach = true where id = v_vt.doi_thuong_id; end if;
  end loop;

  -- (e) Tính tiền
  v_con := greatest(v_tong - v_ck, 0) - v_tra - v_thg - v_treo;
  v_cong := greatest(v_con, 0);
  v_du := greatest(-v_con, 0);
  if v_kh = 'KHLE' and v_ht = 'Ghi nợ' and v_cong > 0 then
    raise exception 'Ghi nợ thì phải chọn hoặc nhập tên khách hàng';
  end if;
  if v_du > 0 then v_cantru := _can_tru_no(v_kh, v_du, v_dh, 'Trừ từ trả hàng/đổi thưởng đơn ' || v_dh); end if;

  update don_hang set tong_tien_hang = v_tong, chiet_khau = v_ck, tong_cong = v_cong,
         tru_tra_hang = v_tra, tru_doi_thuong = v_thg, tru_khac = v_treo,
         tien_can_tru = v_cantru, tien_tra_lai = v_du - v_cantru,
         dt_thuan = greatest(v_tong - v_ck, 0) - v_tra
   where id = v_dh;

  if v_ht = 'Tiền mặt' and v_cong > 0 then
    insert into thanh_toan (khach_hang_id, don_hang_id, so_tien, hinh_thuc, nhan_vien_id, nguoi_thu)
    values (v_kh, v_dh, v_cong, 'Tiền mặt', auth.uid(), v_nv);
  end if;

  return jsonb_build_object('id', v_dh, 'khach_hang_id', v_kh, 'tong_cong', v_cong, 'hinh_thuc', v_ht,
    'tru_tra_hang', v_tra, 'tru_doi_thuong', v_thg, 'tru_khac', v_treo,
    'tien_can_tru', v_cantru, 'tien_tra_lai', v_du - v_cantru, 'cho_kiem_tra', v_cho);
end $function$;

-- Số đẹp kiểu VN: 12000 → 12.000 ; 1.5 → 1,5
create or replace function so_dep(n numeric) returns text language sql immutable as $$
  select case when n = trunc(n) then replace(to_char(n, 'FM999G999G999G990'), ',', '.')
              else replace(rtrim(rtrim(to_char(n, 'FM999999990D999'), '0'), '.'), '.', ',') end
$$;

-- ── 5. HUỶ ĐƠN: gỡ luôn trả hàng, đổi thưởng, cấn trừ, việc treo ─────────
create or replace function public.huy_don_hang(p_id text, p_ly_do text default null) returns void
language plpgsql security definer set search_path = public as $function$
declare v_dh don_hang%rowtype;
begin
  perform _bat_buoc_nhan_vien();
  select * into v_dh from don_hang where id = p_id for update;
  if not found then raise exception 'Không tìm thấy đơn %', p_id; end if;
  if v_dh.trang_thai = 'huy' then raise exception 'Đơn đã huỷ rồi'; end if;
  if not la_chu() and not (v_dh.nhan_vien_id = auth.uid() and v_dh.ngay > now() - interval '30 minutes') then
    raise exception 'Nhân viên chỉ huỷ được đơn của mình trong 30 phút sau khi tạo';
  end if;
  if exists (select 1 from thanh_toan where don_hang_id = p_id) then
    raise exception 'Đơn đã có thanh toán. Hãy huỷ các khoản thanh toán trước';
  end if;
  if exists (select 1 from doi_thuong where don_hang_id = p_id and doi_nap_id is not null) then
    raise exception 'Nắp của đơn này đã mang đổi với NCC – không huỷ được';
  end if;
  if exists (select 1 from viec_treo_khach where don_hang_id = p_id and trang_thai = 'xong') then
    raise exception 'Đơn có khoản treo đã xử lý xong – chủ kiểm tra trước khi huỷ';
  end if;

  -- hàng bán → cộng lại tồn
  update hang_hoa h set ton_kho = h.ton_kho + c.sl
  from (select hang_hoa_id, sum(so_luong * so_luong_quy_doi) sl from don_hang_ct where don_hang_id = p_id group by 1) c
  where h.id = c.hang_hoa_id and h.ton_kho is not null;
  -- hàng khách trả (đã cộng tồn) → trừ lại
  update hang_hoa h set ton_kho = h.ton_kho - c.sl
  from (select hang_hoa_id, sum(so_luong * so_luong_quy_doi) sl from tra_hang
         where don_hang_id = p_id and hang_tot and trang_thai in ('da_tru', 'doi_lay_lai') group by 1) c
  where h.id = c.hang_hoa_id and h.ton_kho is not null;
  -- lon thưởng đã đưa khách → cộng lại
  update hang_hoa h set ton_kho = h.ton_kho + c.sl
  from (select hang_hoa_id, sum(so_nap * so_luong_hang) sl from doi_thuong
         where don_hang_id = p_id and loai = 'hang' and da_tra_khach group by 1) c
  where h.id = c.hang_hoa_id and h.ton_kho is not null;
  update tra_hang set trang_thai = 'huy' where don_hang_id = p_id;
  update doi_thuong set trang_thai = 'huy' where don_hang_id = p_id;
  update viec_treo_khach set trang_thai = 'huy', ket_qua = 'Huỷ đơn ' || p_id where don_hang_id = p_id and trang_thai = 'mo';
  -- khoản treo đã trừ vào đơn này → mở lại
  update viec_treo_khach set trang_thai = 'mo', ket_qua = null, xu_ly_luc = null, nguoi_xu_ly = null
   where trang_thai = 'xong' and ket_qua = 'Trừ vào đơn ' || p_id;
  delete from thanh_toan where tu_don = p_id;   -- gỡ cấn trừ vào nợ cũ
  update don_hang set trang_thai = 'huy', ly_do_huy = p_ly_do where id = p_id;
end $function$;

-- ── 6. XỬ LÝ VIỆC TREO (chỉ chủ) ─────────────────────────────────────────
-- p_kq: 'da_tra' (đã trả khách lon/tiền/hàng) · 'nhan_tra' (vẫn nhận hàng trả) · 'khong_nhan' · 'dong' (bỏ, không làm gì)
create or replace function xu_ly_viec_treo(p_id bigint, p_kq text, p_ghi_chu text default null) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v viec_treo_khach%rowtype; v_th tra_hang%rowtype; v_tru bigint := 0; v_con bigint; v_nv text := _ten_nguoi_dung(); v_kq text;
begin
  perform _bat_buoc_chu();
  select * into v from viec_treo_khach where id = p_id for update;
  if not found then raise exception 'Không tìm thấy việc %', p_id; end if;
  if v.trang_thai <> 'mo' then raise exception 'Việc này đã xử lý rồi'; end if;

  if p_kq = 'dong' then
    v_kq := coalesce(nullif(trim(p_ghi_chu), ''), 'Đóng, không xử lý');
    if v.loai = 'cho_kiem_tra' then update tra_hang set trang_thai = 'khong_nhan', xu_ly_luc = now(), nguoi_xu_ly = v_nv where id = v.tra_hang_id; end if;
  elsif v.loai = 'cho_kiem_tra' and p_kq = 'khong_nhan' then
    update tra_hang set trang_thai = 'khong_nhan', xu_ly_luc = now(), nguoi_xu_ly = v_nv where id = v.tra_hang_id;
    v_kq := 'Không nhận – đã báo khách';
  elsif v.loai = 'cho_kiem_tra' and p_kq = 'nhan_tra' then
    select * into v_th from tra_hang where id = v.tra_hang_id for update;
    if v_th.hang_tot then
      update hang_hoa set ton_kho = ton_kho + v_th.so_luong * v_th.so_luong_quy_doi where id = v_th.hang_hoa_id and ton_kho is not null;
    end if;
    if v_th.thanh_tien = 0 then
      -- là hàng "muốn đổi hàng mới" → chuyển thành việc khách lấy lại
      update tra_hang set trang_thai = 'doi_lay_lai', xu_ly_luc = now(), nguoi_xu_ly = v_nv where id = v_th.id;
      insert into viec_treo_khach (khach_hang_id, loai, noi_dung, hang_hoa_id, so_luong, tra_hang_id, don_hang_id, nguoi_tao)
      values (v.khach_hang_id, 'kh_lay_lai', format('Khách đã trả %s %s %s – chờ lấy lại hàng mới', so_dep(v_th.so_luong), v_th.quy_cach, v_th.ten_hang),
              v_th.hang_hoa_id, v_th.so_luong * v_th.so_luong_quy_doi, v_th.id, v.don_hang_id, v_nv);
      v_kq := 'Nhận trả – chờ khách lấy hàng mới';
    else
      update tra_hang set trang_thai = 'da_nhan_sau', xu_ly_luc = now(), nguoi_xu_ly = v_nv where id = v_th.id;
      -- tiền: trừ nợ cũ trước, còn dư → mình nợ khách (đơn sau trừ hoặc trả tiền)
      v_tru := _can_tru_no(v.khach_hang_id, v_th.thanh_tien, null, 'Nhận trả hàng ' || v_th.id);
      v_con := v_th.thanh_tien - v_tru;
      if v_con > 0 then
        insert into viec_treo_khach (khach_hang_id, loai, noi_dung, so_tien, tra_hang_id, nguoi_tao)
        values (v.khach_hang_id, 'no_tien', format('Nợ khách %s đ tiền trả hàng %s', so_dep(v_con), v_th.ten_hang), v_con, v_th.id, v_nv);
      end if;
      v_kq := format('Nhận trả %s đ: trừ nợ %s đ, còn nợ khách %s đ', so_dep(v_th.thanh_tien), so_dep(v_tru), so_dep(v_con));
    end if;
  elsif p_kq = 'da_tra' and v.loai in ('no_thuong_hang', 'kh_lay_lai') then
    -- đưa hàng cho khách → trừ tồn
    update hang_hoa set ton_kho = ton_kho - v.so_luong where id = v.hang_hoa_id and ton_kho is not null;
    if v.doi_thuong_id is not null then update doi_thuong set da_tra_khach = true where id = v.doi_thuong_id; end if;
    v_kq := 'Đã đưa hàng cho khách';
  elsif p_kq = 'da_tra' and v.loai in ('no_thuong_tien', 'no_tien') then
    -- đưa tiền mặt cho khách → chốt sổ trừ két
    update viec_treo_khach set tien_mat_chi = v.so_tien where id = v.id;
    if v.doi_thuong_id is not null then update doi_thuong set da_tra_khach = true where id = v.doi_thuong_id; end if;
    v_kq := format('Đã trả khách %s đ tiền mặt', so_dep(v.so_tien));
  else
    raise exception 'Không làm được "%" cho việc loại %', p_kq, v.loai;
  end if;
  update viec_treo_khach set trang_thai = 'xong', ket_qua = v_kq || coalesce(' · ' || nullif(trim(p_ghi_chu), ''), ''),
         xu_ly_luc = now(), nguoi_xu_ly = v_nv where id = v.id;
  return jsonb_build_object('ket_qua', v_kq, 'tru_no', v_tru);
end $$;

-- ── 7. CHƯƠNG TRÌNH THƯỞNG & ĐỔI NẮP VỚI NCC (chỉ chủ) ───────────────────
create or replace function luu_chuong_trinh(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_id text := nullif(trim(p->>'id'), ''); m jsonb;
begin
  perform _bat_buoc_chu();
  if nullif(trim(p->>'ten'), '') is null then raise exception 'Chưa nhập tên chương trình'; end if;
  if jsonb_typeof(p->'muc') <> 'array' or jsonb_array_length(p->'muc') = 0 then raise exception 'Chương trình phải có ít nhất 1 mức thưởng'; end if;
  for m in select * from jsonb_array_elements(p->'muc') loop
    if m->>'loai' = 'tien' and coalesce((m->>'gia_tri')::bigint, 0) <= 0 then raise exception 'Mức "%" chưa có số tiền', m->>'ten'; end if;
    if m->>'loai' = 'hang' and (nullif(m->>'hang_hoa_id', '') is null or coalesce((m->>'so_luong')::numeric, 0) <= 0) then
      raise exception 'Mức "%" chưa chọn món / số lượng', m->>'ten'; end if;
    if m->>'loai' not in ('tien', 'hang') then raise exception 'Loại mức không hợp lệ'; end if;
  end loop;
  if v_id is null then
    insert into chuong_trinh_thuong (ten, ncc_id, muc, dang_chay, ghi_chu)
    values (trim(p->>'ten'), nullif(p->>'ncc_id', ''), p->'muc', coalesce((p->>'dang_chay')::boolean, true), nullif(trim(p->>'ghi_chu'), ''))
    returning id into v_id;
  else
    update chuong_trinh_thuong set ten = trim(p->>'ten'), ncc_id = nullif(p->>'ncc_id', ''), muc = p->'muc',
           dang_chay = coalesce((p->>'dang_chay')::boolean, true), ghi_chu = nullif(trim(p->>'ghi_chu'), '') where id = v_id;
  end if;
  return jsonb_build_object('id', v_id);
end $$;

-- Nắp đang giữ (chưa đổi với NCC) của từng chương trình
create or replace view v_nap_dang_giu with (security_invoker = true) as
select c.id, c.ten, c.ncc_id, c.dang_chay, c.muc,
       coalesce(sum(d.so_nap), 0)                                    as so_nap,
       coalesce(sum(d.so_nap * d.gia_tri) filter (where d.loai = 'tien'), 0) as tong_tien,
       coalesce(sum(d.so_nap * d.so_luong_hang) filter (where d.loai = 'hang'), 0) as tong_hang
  from chuong_trinh_thuong c
  left join doi_thuong d on d.chuong_trinh_id = c.id and d.doi_nap_id is null and d.trang_thai = 'hoan_tat'
 group by c.id;
grant select on v_nap_dang_giu to authenticated;

-- Mang toàn bộ nắp đang giữ của 1 chương trình đi đổi. cach: 'tru_no' (trừ nợ NCC) | 'tien_mat' (NCC đưa tiền)
-- Phần thưởng lon: NCC trả lon → cộng tồn kho
create or replace function doi_nap_ncc(p jsonb) returns jsonb
language plpgsql security definer set search_path = public as $$
declare v_ct chuong_trinh_thuong%rowtype; v_id text; v_nap int; v_tien bigint; v_cach text := coalesce(nullif(p->>'cach', ''), 'tru_no'); v_tra bigint; r record;
begin
  perform _bat_buoc_chu();
  select * into v_ct from chuong_trinh_thuong where id = p->>'chuong_trinh_id' for update;
  if not found then raise exception 'Không tìm thấy chương trình'; end if;
  if v_cach not in ('tru_no', 'tien_mat') then raise exception 'Cách đổi không hợp lệ'; end if;
  if v_cach = 'tru_no' and v_ct.ncc_id is null then raise exception 'Chương trình chưa gắn NCC – không trừ nợ được'; end if;
  select coalesce(sum(so_nap), 0), coalesce(sum(so_nap * gia_tri) filter (where loai = 'tien'), 0) into v_nap, v_tien
    from doi_thuong where chuong_trinh_id = v_ct.id and doi_nap_id is null and trang_thai = 'hoan_tat';
  if v_nap = 0 then raise exception 'Không còn nắp nào để đổi'; end if;
  insert into doi_nap_ncc (chuong_trinh_id, ncc_id, so_nap, tong_tien, tong_hang, cach, nguoi_tao)
  values (v_ct.id, v_ct.ncc_id, v_nap, v_tien,
          (select coalesce(sum(so_nap * so_luong_hang), 0) from doi_thuong where chuong_trinh_id = v_ct.id and doi_nap_id is null and trang_thai = 'hoan_tat' and loai = 'hang'),
          v_cach, _ten_nguoi_dung())
  returning id into v_id;
  -- lon NCC trả → cộng tồn
  for r in select hang_hoa_id, sum(so_nap * so_luong_hang) sl from doi_thuong
            where chuong_trinh_id = v_ct.id and doi_nap_id is null and trang_thai = 'hoan_tat' and loai = 'hang' group by 1 loop
    update hang_hoa set ton_kho = ton_kho + r.sl where id = r.hang_hoa_id and ton_kho is not null;
  end loop;
  update doi_thuong set doi_nap_id = v_id where chuong_trinh_id = v_ct.id and doi_nap_id is null and trang_thai = 'hoan_tat';
  if v_tien > 0 and v_cach = 'tru_no' then
    insert into tra_ncc (ncc_id, so_tien, hinh_thuc, nguoi_tra, ghi_chu)
    values (v_ct.ncc_id, v_tien, 'Đổi nắp', _ten_nguoi_dung(), format('Đổi %s nắp – %s (%s)', v_nap, v_ct.ten, v_id))
    returning id into v_tra;
    update doi_nap_ncc set tra_ncc_id = v_tra where id = v_id;
  end if;
  return jsonb_build_object('id', v_id, 'so_nap', v_nap, 'tong_tien', v_tien, 'cach', v_cach);
end $$;

-- ── 8. CHỐT SỔ: trừ tiền mặt trả lại khách, cộng tiền NCC đổi nắp ─────────
create or replace function public.tinh_chot_so(p_ngay date default null) returns jsonb
language plpgsql security definer set search_path = public as $function$
declare
  d date := coalesce(p_ngay, vn_ngay(now()));
  v_quy bigint; v_tm bigint; v_chi bigint; v_ck bigint; v_no bigint; v_don int; v_cho int;
  v_tra_lai bigint; v_chi_treo bigint; v_nap bigint; v_tra_hang bigint; v_thuong bigint; v_cho_kt int;
begin
  perform _bat_buoc_chu();
  select de_lai into v_quy from chot_so where ngay < d order by ngay desc limit 1;
  select coalesce(sum(so_tien) filter (where hinh_thuc = 'Tiền mặt'), 0), coalesce(sum(so_tien) filter (where hinh_thuc = 'Chuyển khoản'), 0)
    into v_tm, v_ck from thanh_toan where vn_ngay(ngay) = d;
  select coalesce(sum(so_tien), 0) into v_chi from tra_ncc where hinh_thuc = 'Tiền mặt' and vn_ngay(ngay) = d;
  select count(*), coalesce(sum(tong_cong) filter (where hinh_thuc = 'Ghi nợ'), 0),
         coalesce(sum(tien_tra_lai), 0), coalesce(sum(tru_tra_hang), 0), coalesce(sum(tru_doi_thuong), 0)
    into v_don, v_no, v_tra_lai, v_tra_hang, v_thuong
    from don_hang where vn_ngay(ngay) = d and trang_thai = 'hoan_tat';
  select coalesce(sum(tien_mat_chi), 0) into v_chi_treo from viec_treo_khach where trang_thai = 'xong' and vn_ngay(xu_ly_luc) = d;
  select coalesce(sum(tong_tien), 0) into v_nap from doi_nap_ncc where cach = 'tien_mat' and vn_ngay(ngay) = d;
  select count(*) into v_cho from don_hang where not da_giao and trang_thai = 'hoan_tat';
  select count(*) into v_cho_kt from viec_treo_khach where trang_thai = 'mo' and loai = 'cho_kiem_tra';
  return jsonb_build_object('ngay', d, 'quy_dau', v_quy,
    'thu_tm', v_tm + v_nap, 'chi_tm', v_chi + v_tra_lai + v_chi_treo, 'thu_ck', v_ck,
    'thu_khach_tm', v_tm, 'thu_nap_ncc', v_nap, 'tra_ncc_tm', v_chi, 'tra_lai_khach', v_tra_lai + v_chi_treo,
    'tru_tra_hang', v_tra_hang, 'tru_doi_thuong', v_thuong, 'cho_kiem_tra', v_cho_kt,
    'ban_no', v_no, 'so_don', v_don, 'cho_giao', v_cho, 'da_chot', (select to_jsonb(c) from chot_so c where ngay = d));
end $function$;

-- ── 9. BÁO CÁO: doanh thu thuần (trừ hàng trả), đổi thưởng không tính là giảm doanh thu ──
create or replace function public.bao_cao(p_tu date, p_den date) returns jsonb
language plpgsql stable security definer set search_path = public as $function$
declare v jsonb;
begin
  perform _bat_buoc_chu();
  with dh as (
    select *, coalesce(dt_thuan, tong_cong) as dt from don_hang where trang_thai = 'hoan_tat' and vn_ngay(ngay) between p_tu and p_den
  ), ct as (
    select c.*, vn_ngay(d.ngay) as ngay_ban, d.khach_hang_id
    from don_hang_ct c join dh d on d.id = c.don_hang_id
  ), von as (
    select don_hang_id,
           sum(so_luong * so_luong_quy_doi * gia_von) as gia_von,
           sum(thanh_tien) filter (where gia_von > 0) as dt_co_von
    from ct group by 1
  ), th as (   -- hàng trả còn tốt nhập lại kho → giảm giá vốn; trả sau (chủ nhận) → giảm doanh thu ngày nhận
    select t.*, coalesce(h.gia_von, 0) as gv_hh from tra_hang t join hang_hoa h on h.id = t.hang_hoa_id
     where (t.trang_thai = 'da_tru' and vn_ngay(t.ngay) between p_tu and p_den)
        or (t.trang_thai = 'da_nhan_sau' and vn_ngay(t.xu_ly_luc) between p_tu and p_den)
  ), th_tong as (
    select coalesce(sum(thanh_tien), 0) as tien,
           coalesce(sum(thanh_tien) filter (where trang_thai = 'da_nhan_sau'), 0) as tien_sau,
           coalesce(round(sum(so_luong * so_luong_quy_doi * gv_hh) filter (where hang_tot)), 0) as von_ve
      from th
  )
  select jsonb_build_object(
    'tong', (select jsonb_build_object(
        'so_don', count(*),
        'doanh_thu', coalesce(sum(d.dt), 0) - (select tien_sau from th_tong),
        'gia_von', coalesce(round(sum(v.gia_von)), 0) - (select von_ve from th_tong),
        'lai_gop', coalesce(sum(d.dt), 0) - (select tien_sau from th_tong) - coalesce(round(sum(v.gia_von)), 0) + (select von_ve from th_tong),
        'ty_le_co_gia_von', case when sum(d.tong_tien_hang) > 0
                                 then round(100.0 * coalesce(sum(v.dt_co_von), 0) / sum(d.tong_tien_hang)) else 0 end,
        'da_thu', (select coalesce(sum(so_tien), 0) from thanh_toan where hinh_thuc <> 'Cấn trừ' and vn_ngay(ngay) between p_tu and p_den),
        'ghi_no', coalesce(sum(d.tong_cong) filter (where d.hinh_thuc = 'Ghi nợ'), 0),
        'tra_hang', (select tien from th_tong),
        'doi_thuong', coalesce(sum(d.tru_doi_thuong), 0),
        'tra_lai_khach', coalesce(sum(d.tien_tra_lai), 0))
      from dh d left join von v on v.don_hang_id = d.id),
    'theo_ngay', (select coalesce(jsonb_agg(x order by x.ngay), '[]'::jsonb) from (
        select vn_ngay(d.ngay) as ngay, count(*) as so_don, sum(d.dt) as doanh_thu,
               sum(d.dt) - coalesce(round(sum(v.gia_von)), 0) as lai_gop
        from dh d left join von v on v.don_hang_id = d.id group by 1) x),
    'hang_ban_chay', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select hang_hoa_id, max(ten_hang) as ten, sum(so_luong * so_luong_quy_doi) as so_luong_nho,
               sum(thanh_tien) as doanh_thu, count(distinct don_hang_id) as so_don
        from ct group by 1 order by sum(thanh_tien) desc limit 30) x),
    'khach_mua_nhieu', (select coalesce(jsonb_agg(x), '[]'::jsonb) from (
        select d.khach_hang_id, k.ten, count(*) as so_don, sum(d.dt) as doanh_thu
        from dh d join khach_hang k on k.id = d.khach_hang_id
        where d.khach_hang_id <> 'KHLE'
        group by 1, 2 order by sum(d.dt) desc limit 30) x),
    'theo_hinh_thuc', (select coalesce(jsonb_object_agg(hinh_thuc, tien), '{}'::jsonb) from (
        select hinh_thuc, sum(tong_cong) tien from dh group by 1) x)
  ) into v;
  return v;
end $function$;

grant execute on function gia_tra_hang(text, text, text), xu_ly_viec_treo(bigint, text, text), luu_chuong_trinh(jsonb), doi_nap_ncc(jsonb), so_dep(numeric) to authenticated;
revoke execute on function _con_duoc_tra(text, text), _can_tru_no(text, bigint, text, text) from public, anon, authenticated;

-- ── 10. v_don_hang: thêm các cột TH01 vào CUỐI (giữ nguyên cột cũ, v_cong_no_khach không đổi) ──
create or replace view public.v_don_hang with (security_invoker = true) as
 SELECT d.id, d.khach_hang_id, d.ngay, d.nhan_vien_id, d.nguoi_tao, d.kenh, d.hinh_thuc, d.tong_tien_hang, d.chiet_khau, d.tong_cong,
    d.ghi_chu, d.trang_thai, d.ly_do_huy, d.da_giao, d.ma_phieu, d.giao_luc, d.nguoi_giao,
    k.ten AS ten_khach, k.sdt AS sdt_khach,
    COALESCE(t.da_tra, 0::numeric) AS da_tra,
    CASE WHEN d.trang_thai = 'huy'::text THEN 0::numeric
         ELSE GREATEST(d.tong_cong::numeric - COALESCE(t.da_tra, 0::numeric), 0::numeric) END AS con_no,
    d.tru_tra_hang, d.tru_doi_thuong, d.tru_khac, d.tien_can_tru, d.tien_tra_lai, d.dt_thuan
   FROM don_hang d
     JOIN khach_hang k ON k.id = d.khach_hang_id
     LEFT JOIN ( SELECT thanh_toan.don_hang_id, sum(thanh_toan.so_tien) AS da_tra FROM thanh_toan GROUP BY thanh_toan.don_hang_id) t ON t.don_hang_id = d.id;

commit;
-- Báo PostgREST đọc lại cấu trúc mới
notify pgrst, 'reload schema';
