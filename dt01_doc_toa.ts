// ═══════════════════════════════════════════════════════════════════
// Supabase Edge Function "doc_toa" – DT01 (anh Tâm duyệt 13/11/2026)
// App gửi: 1–4 ảnh toa (base64 JPEG) + danh mục hàng "mã|tên|đơn vị nhỏ|quy cách:số đv,…" + tên NCC + mã SP đã biết.
// Claude đọc toa → trả từng dòng ĐÚNG NHƯ IN TRÊN TOA (thùng, lẻ, giá, thành tiền, KM…). App tự quy đổi + kiểm tổng.
//   • Không tự cộng / trừ theo chữ viết tay – chỉ báo lên (ghi_chu_tay).
//   • Khoá API: Secret ANTHROPIC_API_KEY (đã có từ BG01). Đổi model: Secret AI_MODEL_TOA (vd claude-sonnet-5-5).
// ═══════════════════════════════════════════════════════════════════

const MODEL = Deno.env.get('AI_MODEL_TOA') ?? Deno.env.get('AI_MODEL') ?? 'claude-haiku-5-5';            // đọc lần đầu (rẻ)
const MODEL_MANH = Deno.env.get('AI_MODEL_TOA_MANH') ?? 'claude-sonnet-5-5';                                // "🔁 Đọc lại kỹ" khi tổng lệch
const AI_URL = Deno.env.get('ANTHROPIC_URL') ?? 'https://api.anthropic.com/v1/messages';
const SB_URL = Deno.env.get('SUPABASE_URL')!;
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (o: unknown, code = 200) => new Response(JSON.stringify(o), { status: code, headers: { ...CORS, 'Content-Type': 'application/json' } });

// Hướng dẫn đọc toa. Gặp mẫu toa mới hay sai → bổ sung 1 dòng ở đây + ghi vào Bài học.
const HUONG_DAN = `Bạn là kế toán kho của 1 tiệm tạp hoá ở Đà Nẵng. Đọc ảnh phiếu giao hàng / toa của nhà phân phối (NPP) và gọi công cụ tra_toa.
Ảnh có thể nghiêng, XOAY NGANG 90°, có bóng, có chữ viết tay. Nhiều ảnh = nhiều trang của CÙNG 1 toa.
Ảnh xoay ngang: xoay lại cho đúng chiều rồi đọc theo từng HÀNG NGANG của bảng – mã, tên, thùng, lẻ, đơn giá, thành tiền của 1 dòng phải nằm cùng 1 hàng. Không lấy số của hàng trên/dưới.

ĐỌC ĐÚNG NHƯ IN, KHÔNG TỰ TÍNH LẠI. Mỗi dòng hàng (kể cả dòng khuyến mãi) trả về:
- ma: mã sản phẩm in trên toa (vd TPNDTOPET02, 04EI13, 02OM00771, 301000292); không có thì "".
- ten: tên in trên toa.
- id: mã món trong DANH MỤC của tiệm khớp nhất ("" nếu không có món nào khớp). Nếu MÃ ĐÃ BIẾT có mã này thì dùng đúng id đó.
  Chú ý phân biệt vị / loại: "T. ớt" = tương ỚT, "T. Cà" = tương CÀ; "STTT" = sữa tiệt trùng; "SDD" = sữa dinh dưỡng; "SCA" = sữa chua ăn; "NSPN" = sữa đặc Ngôi Sao Phương Nam.
- qc: số đơn vị nhỏ trong 1 thùng. Lấy cột "QC" nếu có; không có thì đọc trong tên (vd "30gói x 80gr" → 30, "12x700" → 12, "24 chai" → 24, "(24)" → 24); không biết → 0.
- tang_moi_thung: số đơn vị tặng kèm mỗi thùng ghi trong tên kiểu "30+2 gói" → 2 (khi đó qc = 30). Không có → 0.
- thung, le: số thùng và số lẻ (đơn vị nhỏ) ở cột "Thùng", "Lẻ". Toa chỉ có cột "SL" + ĐVT/Đơn vị "Thùng"/"T" → thung = SL, le = 0. Ô "-" hoặc trống = 0.
- gia: đơn giá in trên toa; gia_theo: "thung" nếu là giá 1 thùng, "don_vi" nếu là giá 1 hộp/gói/chai (vd cột "Đơn giá Lẻ", hoặc đơn giá nhỏ hơn nhiều so với thành tiền/số thùng).
  Có 2 cột đơn giá trước VAT (T.VAT) và sau VAT (S.VAT) → lấy giá SAU VAT.
  Toa chỉ có cột "Đơn giá Lẻ" (kiểu Masan) → đó là giá 1 gói/chai: gia = giá đó, gia_theo = "don_vi", và thành tiền = (thùng × qc + lẻ) × giá.
- gia_le: giá 1 đơn vị lẻ nếu toa có cột riêng (vd "Giá lẻ"), không có → 0.
- tt: thành tiền phải trả của dòng (lấy "Thành tiền sau CK" nếu có). Dòng khuyến mãi / tặng → 0.
- ck: tiền chiết khấu riêng của dòng (cột "Tiền CK") nếu có, không có → 0.
- km: true nếu là hàng khuyến mãi / tặng / trưng bày không tính tiền: dòng nằm trong bảng "Hàng khuyến mãi", cột "SP Tặng", hoặc có "Số tiền KM/TB" mà thành tiền trống/0.
  QUAN TRỌNG: nhiều toa (vd Vinamilk/DMS.ONE) có BẢNG "Hàng khuyến mãi" RIÊNG nằm DƯỚI bảng chính (cột Mã hàng, Tên hàng, QC, Thùng, Lẻ, Chương trình bán hàng).
  MỖI hàng của bảng đó phải trả về 1 dòng riêng với km = true (dù không có giá). Đừng bỏ sót bảng này.
  Hàng tặng là món KHÁC món mua (vd mua dầu 5L tặng chai 1L) → vẫn 1 dòng km riêng với đúng tên món tặng, số lượng theo ĐVT in (vd "24 Chai" → thung 0, le 24).
  "Chiết khấu" tiền trong cột SP tặng KHÔNG phải hàng → không thành dòng, cộng vào ck_toa.
- chac: 0–1 độ chắc chắn dòng này đọc đúng (ảnh mờ, bị gạch sửa → thấp).

Toàn toa: so_toa (số hoá đơn / mã ĐH), ngay (YYYY-MM-DD), ncc_ten, tong_hang (tổng tiền hàng trước chiết khấu toa),
ck_toa (tổng tiền chiết khấu / trả thưởng / giảm giá / tặng tiền CẢ TOA – số dương, không gồm CK đã trừ trong từng dòng;
  gồm mọi dòng như "Tiền chiết khấu hóa đơn", "Chiết khấu", "Tặng tiền trên hóa đơn", "Trả thưởng trưng bày", "Tổng tiền CK/Trả thưởng"),
tong_phai_tra ("Tổng tiền phải trả" / "Tổng tiền thanh toán" / "Còn lại" IN trên toa), km_tong (tổng giá trị hàng KM nếu in), cuoc_vo (tiền cược vỏ nếu có).
ghi_chu_tay: liệt kê NGUYÊN VĂN mọi chữ viết tay có ý nghĩa tiền / hàng (vd "Hỗ trợ 51 hộp NSPN XL 380g", "trừ 80k", số lượng bị gạch sửa "144 → 2"). Bỏ qua chữ ký, "Mai Mai", "CK", "đã giao".
BỎ QUA: điểm tích luỹ, "Giá trị VC", số trang, mã QR, các dòng tổng ("Tổng tiền hàng", "Tổng cộng", "Tổng số lượng") – không phải dòng hàng. Không bịa dòng không có trên toa.
TỰ KIỂM TRƯỚC KHI TRẢ: mỗi dòng (thùng × giá thùng + lẻ × giá lẻ, hoặc (thùng × qc + lẻ) × giá đơn vị) − ck phải ≈ tt; và tổng tt các dòng không KM − ck_toa phải ≈ tong_phai_tra.
Nếu lệch → nhìn lại ảnh, đọc lại các số cho đúng hàng rồi mới trả. Vẫn không khớp thì hạ chac của dòng nghi ngờ.`;

const CONG_CU = {
  name: 'tra_toa', description: 'Trả nội dung toa nhà phân phối',
  input_schema: {
    type: 'object',
    properties: {
      so_toa: { type: 'string' }, ngay: { type: 'string' }, ncc_ten: { type: 'string' },
      dong: { type: 'array', items: { type: 'object', properties: {
        ma: { type: 'string' }, ten: { type: 'string' }, id: { type: 'string' }, qc: { type: 'number' }, tang_moi_thung: { type: 'number' },
        thung: { type: 'number' }, le: { type: 'number' }, gia: { type: 'number' }, gia_theo: { type: 'string', enum: ['thung', 'don_vi'] },
        gia_le: { type: 'number' }, tt: { type: 'number' }, ck: { type: 'number' }, km: { type: 'boolean' }, chac: { type: 'number' },
      }, required: ['ten', 'id', 'thung', 'le', 'km', 'chac'] } },
      tong_hang: { type: 'number' }, ck_toa: { type: 'number' }, tong_phai_tra: { type: 'number' }, km_tong: { type: 'number' },
      cuoc_vo: { type: 'number' }, ghi_chu_tay: { type: 'array', items: { type: 'string' } },
    },
    required: ['dong', 'tong_phai_tra'],
  },
};

const so = (x: unknown) => { const n = Number(x); return Number.isFinite(n) && n > 0 ? n : 0; };

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  const auth = req.headers.get('Authorization') ?? '';
  const apikey = req.headers.get('apikey') ?? Deno.env.get('SUPABASE_ANON_KEY') ?? '';
  const sql = async (ham: string, thamSo: unknown) => {
    const r = await fetch(`${SB_URL}/rest/v1/rpc/${ham}`, { method: 'POST', headers: { Authorization: auth, apikey, 'Content-Type': 'application/json' }, body: JSON.stringify(thamSo) });
    const t = await r.text(); const j = t ? JSON.parse(t) : null;
    if (!r.ok) throw Object.assign(new Error((j && j.message) || 'Lỗi máy chủ'), { code: r.status });
    return j;
  };
  let id: number | null = null;
  try {
    const b = await req.json();
    const anh: string[] = (Array.isArray(b.anh) ? b.anh : []).filter((x: unknown) => typeof x === 'string' && x.length > 100).slice(0, 4);
    const ds = String(b.ds ?? '').slice(0, 300000), ncc = String(b.ncc ?? '').slice(0, 200), maBiet = String(b.ma_biet ?? '').slice(0, 20000);
    if (!anh.length) return json({ loi: 'Chưa có ảnh toa' }, 400);
    if (!ds.trim()) return json({ loi: 'Chưa có danh mục hàng' }, 400);

    const model = b.manh === true ? MODEL_MANH : MODEL;
    id = await sql('ai_bat_dau', { p_tin: 'Toa ' + ncc + (b.manh === true ? ' (đọc kỹ)' : ''), p_so_anh: anh.length, p_so_ung_vien: ds.split('\n').length, p_viec: 'doc_toa' });
    const key = Deno.env.get('ANTHROPIC_API_KEY');
    if (!key) throw new Error('Chưa cài khoá AI (ANTHROPIC_API_KEY) trong Supabase → Edge Functions → Secrets');

    const noiDung = [
      ...anh.map((a) => ({ type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: a } })),
      { type: 'text', text: `NHÀ CUNG CẤP (theo app): ${ncc || '(chưa rõ)'}\nMÃ ĐÃ BIẾT (mã trên toa=id):\n${maBiet || '(chưa có)'}\n\nDANH MỤC (id|tên|đơn vị nhỏ|quy cách:số đơn vị):\n${ds}` },
    ];
    // Bắt buộc gọi công cụ tra_toa; model nào không hỗ trợ kiểu bắt buộc (vd Sonnet 5.5) → gửi lại kiểu "auto" + dặn phải gọi công cụ
    const hoiAI = (tc: unknown) => fetch(AI_URL, {
      method: 'POST',
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({ model, max_tokens: b.manh === true ? 16000 : 8000,   // đọc kỹ: model mạnh hay viết dài hơn → cho nhiều chỗ hơn
        system: HUONG_DAN + (tc ? '' : '\nBẮT BUỘC trả lời bằng cách gọi công cụ tra_toa (không viết chữ).'),
        tools: [CONG_CU], ...(tc ? { tool_choice: tc } : {}), messages: [{ role: 'user', content: noiDung }] }),
    });
    let r = await hoiAI({ type: 'tool', name: 'tra_toa' });
    let j = await r.json().catch(() => ({}));
    if (r.status === 400 && /tool_choice/.test((j.error && j.error.message) || '')) { r = await hoiAI(null); j = await r.json().catch(() => ({})); }
    if (!r.ok) throw new Error('AI báo lỗi ' + r.status + ': ' + ((j.error && j.error.message) || ''));
    // Hết chỗ trả lời giữa chừng → kết quả bị cắt cụt (thường ra 0 dòng): báo rõ thay vì trả toa rỗng
    if (j.stop_reason === 'max_tokens') throw new Error('Toa dài quá, AI chưa đọc xong – chụp lại thẳng, rõ (hoặc chia 2 ảnh) rồi đọc lại');
    const tuDung = (j.content || []).find((c: { type: string }) => c.type === 'tool_use');
    if (!tuDung) throw new Error('AI không trả kết quả đúng dạng – thử lại');
    const tu = tuDung.input || {};
    const kq = {
      so_toa: String(tu.so_toa ?? '').slice(0, 60), ngay: String(tu.ngay ?? '').slice(0, 10), ncc_ten: String(tu.ncc_ten ?? '').slice(0, 200),
      dong: (Array.isArray(tu.dong) ? tu.dong : []).slice(0, 80).map((d: Record<string, unknown>) => ({
        ma: String(d.ma ?? '').trim().toUpperCase().slice(0, 40), ten: String(d.ten ?? '').slice(0, 200), id: String(d.id ?? ''),
        qc: so(d.qc), tang_moi_thung: so(d.tang_moi_thung), thung: so(d.thung), le: so(d.le),
        gia: so(d.gia), gia_theo: d.gia_theo === 'don_vi' ? 'don_vi' : 'thung', gia_le: so(d.gia_le), tt: so(d.tt), ck: so(d.ck),
        km: d.km === true, chac: Math.max(0, Math.min(1, Number(d.chac) || 0)),
      })),
      tong_hang: so(tu.tong_hang), ck_toa: so(tu.ck_toa), tong_phai_tra: so(tu.tong_phai_tra), km_tong: so(tu.km_tong), cuoc_vo: so(tu.cuoc_vo),
      ghi_chu_tay: (Array.isArray(tu.ghi_chu_tay) ? tu.ghi_chu_tay : []).map(String).slice(0, 10),
    };
    await sql('ai_ket_thuc', { p_id: id, p_ket_qua: kq, p_loi: null, p_token_vao: j.usage?.input_tokens ?? null, p_token_ra: j.usage?.output_tokens ?? null });
    return json({ id, model, ...kq });
  } catch (e) {
    const msg = String((e as Error).message || e);
    if (id) await sql('ai_ket_thuc', { p_id: id, p_ket_qua: null, p_loi: msg, p_token_vao: null, p_token_ra: null }).catch(() => {});
    const code = (e as { code?: number }).code;
    return json({ loi: msg }, code === 401 || code === 403 ? 401 : 400);
  }
});
