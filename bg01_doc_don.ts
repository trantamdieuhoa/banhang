// ═══════════════════════════════════════════════════════════════════
// Supabase Edge Function "doc_don" – BG01 (anh Tâm duyệt 13/11/2026)
// App gửi: tin khách dán từ Zalo + ảnh (base64 JPEG, tối đa 4) + danh sách ỨNG VIÊN "mã|tên|quy cách".
// Hàm hỏi Claude Haiku → trả về từng món: mã, quy cách, số lượng, độ chắc chắn.
//   • AI KHÔNG trả giá. Giá do app lấy từ bảng giá.
//   • Khoá API nằm ở Supabase → Edge Functions → Secrets (ANTHROPIC_API_KEY), không nằm trong app công khai.
//   • Mỗi lượt ghi 1 dòng vào bảng ai_doc_don (giới hạn 300 lượt/ngày nằm trong hàm SQL ai_bat_dau).
// Muốn đổi model: thêm Secret AI_MODEL (vd claude-sonnet-5-5). Mặc định claude-haiku-5-5 cho rẻ.
// ═══════════════════════════════════════════════════════════════════

const MODEL = Deno.env.get('AI_MODEL') ?? 'claude-haiku-5-5';
const AI_URL = Deno.env.get('ANTHROPIC_URL') ?? 'https://api.anthropic.com/v1/messages';   // chỉ đổi khi chạy thử
const SB_URL = Deno.env.get('SUPABASE_URL')!;
const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const json = (o: unknown, code = 200) => new Response(JSON.stringify(o), { status: code, headers: { ...CORS, 'Content-Type': 'application/json' } });

// Hướng dẫn cho AI. Sửa ở đây nếu AI hay hiểu sai 1 kiểu nào đó (ghi lại vào Bài học).
const HUONG_DAN = `Bạn là nhân viên tiệm tạp hóa ở Đà Nẵng, đọc tin nhắn / ảnh khách đặt hàng qua Zalo và ghi lại từng món.
Bạn được đưa DANH MỤC (mỗi dòng: mã|tên hàng|các quy cách có giá) và TIN KHÁCH (và/hoặc ảnh). Gọi công cụ tra_don để trả kết quả.

Quy tắc:
1. Chỉ chọn mã CÓ trong DANH MỤC. Không có món nào khớp → id = "" và chac = 0. Không tự thay bằng món khác.
2. TUYỆT ĐỐI không ghi giá, không tự giảm giá. Khách xin giảm giá, hẹn giờ giao, dặn dò → chép ý đó vào ghi_chu.
3. Quy cách lấy theo chữ khách: thùng, lốc, gói, két, chai, lon, bịch, hộp, kg, chục, cây… "5 gói mì" là 5 gói, KHÔNG phải 5 thùng.
   qc phải là 1 quy cách có trong dòng danh mục của món đó. Khách không nói quy cách → chọn quy cách hay bán lẻ nhất, chac ≤ 0.6.
4. Khách không nói số lượng → sl = 1, chac ≤ 0.6. Hiểu được "nửa thùng" = 0.5 thùng, "1 chục" = quy cách chục nếu có.
5. Món mơ hồ (vd "hảo hảo" mà tiệm có nhiều vị): id = món phổ biến nhất, đưa 2–3 mã khác có thể đúng vào khac, chac ≤ 0.6.
6. Khách viết không dấu, viết tắt, sai chính tả: "sg" = Sài Gòn, "tg" = Tiger, "nc" = nước, "e/em", "a/anh", "c/chị", "th" = thùng hoặc TH true milk tuỳ ngữ cảnh.
7. ten_khach: tên người / quán nếu tin tự giới thiệu (vd "chị Năm quán bún", "quán Cô Ba"); không có thì "".
8. goc = đúng đoạn chữ của khách nói về món đó (ngắn gọn). Không bịa món không có trong tin / ảnh.
9. Ảnh: đọc chữ trong ảnh chụp màn hình Zalo hoặc giấy ghi tay; chữ mờ, không chắc → chac thấp. Ảnh chụp sản phẩm → nhận ra sản phẩm.
10. chac: 0.9–1 khi chắc chắn đúng món + quy cách + số lượng; thấp hơn khi phải đoán.`;

const CONG_CU = {
  name: 'tra_don',
  description: 'Trả danh sách món khách đặt',
  input_schema: {
    type: 'object',
    properties: {
      dong: {
        type: 'array',
        items: {
          type: 'object',
          properties: {
            goc: { type: 'string', description: 'đoạn chữ gốc của khách' },
            id: { type: 'string', description: 'mã hàng trong danh mục, "" nếu không có' },
            qc: { type: 'string', description: 'quy cách' },
            sl: { type: 'number', description: 'số lượng' },
            chac: { type: 'number', description: 'độ chắc chắn 0–1' },
            khac: { type: 'array', items: { type: 'string' }, description: 'mã các món khác có thể đúng' },
          },
          required: ['goc', 'id', 'qc', 'sl', 'chac'],
        },
      },
      ten_khach: { type: 'string' },
      ghi_chu: { type: 'string' },
    },
    required: ['dong'],
  },
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  // Gọi hàm SQL bằng CHÍNH phiên đăng nhập của người dùng → chưa đăng nhập thì Supabase tự chặn
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
    const tin = String(b.tin ?? '').slice(0, 4000);
    const anh: string[] = (Array.isArray(b.anh) ? b.anh : []).filter((x: unknown) => typeof x === 'string' && x.length > 100).slice(0, 4);
    const ds = String(b.ds ?? '').slice(0, 200000);
    if (!tin.trim() && !anh.length) return json({ loi: 'Chưa có tin nhắn hoặc ảnh' }, 400);
    if (!ds.trim()) return json({ loi: 'Chưa có danh mục hàng' }, 400);

    id = await sql('ai_bat_dau', { p_tin: tin, p_so_anh: anh.length, p_so_ung_vien: ds.split('\n').length });

    const key = Deno.env.get('ANTHROPIC_API_KEY');
    if (!key) throw new Error('Chưa cài khoá AI (ANTHROPIC_API_KEY) trong Supabase → Edge Functions → Secrets');
    const noiDung = [
      ...anh.map((a) => ({ type: 'image', source: { type: 'base64', media_type: 'image/jpeg', data: a } })),
      { type: 'text', text: `DANH MỤC (mã|tên|quy cách):\n${ds}\n\nTIN KHÁCH:\n${tin.trim() || '(không có chữ – đọc ảnh)'}` },
    ];
    const r = await fetch(AI_URL, {
      method: 'POST',
      headers: { 'x-api-key': key, 'anthropic-version': '2023-06-01', 'content-type': 'application/json' },
      body: JSON.stringify({ model: MODEL, max_tokens: 2000, system: HUONG_DAN, tools: [CONG_CU], tool_choice: { type: 'tool', name: 'tra_don' }, messages: [{ role: 'user', content: noiDung }] }),
    });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error('AI báo lỗi ' + r.status + ': ' + ((j.error && j.error.message) || ''));
    const tu = ((j.content || []).find((c: { type: string }) => c.type === 'tool_use') || {}).input || {};
    // Làm sạch kết quả: chỉ giữ đúng các trường cần, số lượng > 0, độ chắc 0–1
    const kq = {
      dong: (Array.isArray(tu.dong) ? tu.dong : []).slice(0, 60).map((d: Record<string, unknown>) => ({
        goc: String(d.goc ?? '').slice(0, 200), id: String(d.id ?? ''), qc: String(d.qc ?? ''),
        sl: Number(d.sl) > 0 ? Number(d.sl) : 1, chac: Math.max(0, Math.min(1, Number(d.chac) || 0)),
        khac: (Array.isArray(d.khac) ? d.khac : []).map(String).slice(0, 3),
      })),
      ten_khach: String(tu.ten_khach ?? '').slice(0, 100),
      ghi_chu: String(tu.ghi_chu ?? '').slice(0, 500),
    };
    await sql('ai_ket_thuc', { p_id: id, p_ket_qua: kq, p_loi: null, p_token_vao: j.usage?.input_tokens ?? null, p_token_ra: j.usage?.output_tokens ?? null });
    return json({ id, ...kq });
  } catch (e) {
    const msg = String((e as Error).message || e);
    if (id) await sql('ai_ket_thuc', { p_id: id, p_ket_qua: null, p_loi: msg, p_token_vao: null, p_token_ra: null }).catch(() => {});
    const code = (e as { code?: number }).code;
    return json({ loi: msg }, code === 401 || code === 403 ? 401 : 400);
  }
});
