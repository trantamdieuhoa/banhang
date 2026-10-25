// Service worker của app Bán hàng: giữ sẵn app trên máy để MẤT MẠNG vẫn mở được.
// Cách làm "mạng trước": có mạng → luôn lấy bản mới nhất (cập nhật app như bình thường) rồi cất 1 bản;
// mất mạng → dùng bản đã cất. Chỉ cất file của chính app (index.html, manifest, icon),
// KHÔNG cất dữ liệu Supabase (dữ liệu hàng/khách đã được app lưu riêng trên máy).
const KHO = 'banhang-v1';
const FILE_APP = ['./', './index.html', './manifest.json', './icon-180.png', './icon-192.png', './icon-512.png'];

self.addEventListener('install', e => {
  e.waitUntil(caches.open(KHO).then(c => c.addAll(FILE_APP)).then(() => self.skipWaiting()));
});
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ds => Promise.all(ds.filter(k => k !== KHO).map(k => caches.delete(k))))
    .then(() => self.clients.claim()));
});
self.addEventListener('fetch', e => {
  const r = e.request;
  if (r.method !== 'GET' || new URL(r.url).origin !== self.location.origin) return;   // Supabase, Apps Script, CDN: để nguyên
  e.respondWith(
    fetch(r).then(res => {
      if (res.ok) { const ban = res.clone(); caches.open(KHO).then(c => c.put(r, ban)); }
      return res;
    }).catch(() => caches.match(r, { ignoreSearch: true })
      .then(c => c || (r.mode === 'navigate' ? caches.match('./index.html') : undefined))
      .then(c => c || new Response('Mất mạng và chưa có bản lưu', { status: 503, headers: { 'Content-Type': 'text/plain; charset=utf-8' } })))
  );
});
