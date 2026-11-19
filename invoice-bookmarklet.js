// Bookmarklet: chạy trên trang https://hoadondientu.gdt.gov.vn (cùng origin nên fetch không bị CORS).
// Cách dùng: copy toàn bộ nội dung file này, tạo bookmark với URL: javascript:(function(){ ... })();
// Hoặc dán vào Console DevTools khi đang ở trang thuế.

(function () {
  if (window.__invTool) { window.__invTool.remove(); delete window.__invTool; return; }
  const base = location.origin;
  let token = localStorage.getItem('inv_token') || '';
  let captchaKey = '';
  const uuid = () => 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, c => { const r = Math.random()*16|0; return (c==='x'?r:(r&0x3|0x8)).toString(16); });

  const panel = document.createElement('div');
  panel.style.cssText = 'position:fixed;bottom:10px;right:10px;width:360px;max-height:90vh;overflow:auto;background:#fff;border:1px solid #ccc;border-radius:10px;padding:12px;box-shadow:0 4px 12px rgba(0,0,0,.2);z-index:999999;font:13px -apple-system,sans-serif;';
  panel.innerHTML = `
    <div style="display:flex;justify-content:space-between;align-items:center;margin-bottom:8px">
      <b>Tải hóa đơn</b>
      <button id="invClose" style="border:none;background:#eee;border-radius:6px;padding:4px 8px;cursor:pointer">✕</button>
    </div>
    <label>MST</label><input id="invMst" style="width:100%;padding:6px;margin:4px 0">
    <label>Mật khẩu</label><input id="invPass" type="password" style="width:100%;padding:6px;margin:4px 0">
    <button id="invSave" style="width:100%;padding:6px;margin:4px 0;background:#6c757d;color:#fff;border:none;border-radius:6px;cursor:pointer">Lưu tài khoản</button>
    <div id="invAccts" style="max-height:80px;overflow:auto;border:1px solid #eee;margin:4px 0"></div>
    <button id="invCaptcha" style="width:100%;padding:6px;margin:4px 0;background:#6c757d;color:#fff;border:none;border-radius:6px;cursor:pointer">Tải captcha</button>
    <img id="invCaptchaImg" style="width:100%;border:1px solid #ccc;border-radius:6px;margin:4px 0;display:none">
    <input id="invCaptchaVal" placeholder="Nhập captcha" style="width:100%;padding:6px;margin:4px 0">
    <button id="invLogin" style="width:100%;padding:6px;margin:4px 0;background:#2d6cdf;color:#fff;border:none;border-radius:6px;cursor:pointer">Đăng nhập</button>
    <div id="invLoginStatus" style="font-size:12px;color:#555;margin:4px 0"></div>
    <label>Từ ngày (dd/mm/yyyy)</label><input id="invFrom" value="01/10/2025" style="width:100%;padding:6px;margin:4px 0">
    <label>Đến ngày</label><input id="invTo" value="31/10/2025" style="width:100%;padding:6px;margin:4px 0">
    <label>Loại</label><select id="invType" style="width:100%;padding:6px;margin:4px 0"><option value="buy">Mua vào</option><option value="sold">Bán ra</option></select>
    <button id="invList" style="width:100%;padding:6px;margin:4px 0;background:#6c757d;color:#fff;border:none;border-radius:6px;cursor:pointer">Xem danh sách</button>
    <button id="invDownload" style="width:100%;padding:6px;margin:4px 0;background:#28a745;color:#fff;border:none;border-radius:6px;cursor:pointer">Tải Excel</button>
    <div id="invStatus" style="font-size:12px;white-space:pre-wrap;background:#111;color:#0f0;padding:8px;border-radius:6px;min-height:60px;max-height:160px;overflow:auto;margin-top:6px"></div>
  `;
  document.body.appendChild(panel);
  window.__invTool = { remove: () => panel.remove() };

  const log = m => { const el = document.getElementById('invStatus'); el.textContent += `[${new Date().toLocaleTimeString()}] ${m}\n`; el.scrollTop = el.scrollHeight; };
  const accounts = JSON.parse(localStorage.getItem('inv_accounts') || '[]');
  const renderAccts = () => {
    const el = document.getElementById('invAccts'); el.innerHTML = '';
    accounts.forEach(a => {
      const d = document.createElement('div');
      d.style.cssText = 'padding:4px;border-bottom:1px solid #eee;cursor:pointer';
      d.textContent = a.mst;
      d.onclick = () => { document.getElementById('invMst').value = a.mst; document.getElementById('invPass').value = a.pass; };
      el.appendChild(d);
    });
    if (!accounts.length) el.innerHTML = '<div style="padding:4px;color:#999">Chưa có tài khoản</div>';
  };
  renderAccts();

  document.getElementById('invClose').onclick = () => { panel.remove(); delete window.__invTool; };
  document.getElementById('invSave').onclick = () => {
    const mst = document.getElementById('invMst').value.trim();
    const pass = document.getElementById('invPass').value;
    if (!mst) return log('Thiếu MST');
    const idx = accounts.findIndex(a => a.mst === mst);
    if (idx >= 0) accounts[idx].pass = pass; else accounts.push({ mst, pass });
    localStorage.setItem('inv_accounts', JSON.stringify(accounts));
    renderAccts(); log('Đã lưu ' + mst);
  };

  const api = async (path, opts = {}) => {
    const headers = {
      'accept': 'application/json, text/plain, */*',
      'accept-language': 'vi',
      'action': opts.action || '',
      'end-point': opts.endPoint || '/',
      'request-id': uuid(),
      ...(opts.headers || {})
    };
    if (token) headers['authorization'] = 'Bearer ' + token;
    const res = await fetch(base + path, { credentials: 'include', headers, ...opts });
    const ct = res.headers.get('content-type') || '';
    let body;
    if (ct.includes('json')) body = await res.json();
    else if (ct.includes('spreadsheet') || ct.includes('octet')) body = await res.blob();
    else body = await res.text();
    if (!res.ok) throw new Error(res.status + ' ' + res.statusText + ': ' + (typeof body === 'string' ? body : JSON.stringify(body).slice(0,200)));
    return { res, body };
  };

  document.getElementById('invCaptcha').onclick = async () => {
    try {
      log('Tải captcha...');
      const { body } = await api('/api/captcha');
      captchaKey = body.key;
      const img = document.getElementById('invCaptchaImg');
      img.src = 'data:image/svg+xml;utf8,' + encodeURIComponent(body.content);
      img.style.display = 'block';
      log('Captcha OK (key=' + captchaKey + ')');
    } catch (e) { log('Lỗi captcha: ' + e.message); }
  };

  document.getElementById('invLogin').onclick = async () => {
    const mst = document.getElementById('invMst').value.trim();
    const pass = document.getElementById('invPass').value;
    const captcha = document.getElementById('invCaptchaVal').value.trim();
    if (!mst || !pass || !captcha || !captchaKey) return log('Thiếu MST/pass/captcha');
    try {
      log('Đăng nhập ' + mst + '...');
      const { body } = await api('/api/security-taxpayer/authenticate', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ username: mst, password: pass, cvalue: captcha, ckey: captchaKey })
      });
      token = body.token;
      localStorage.setItem('inv_token', token);
      log('Đăng nhập OK');
      document.getElementById('invLoginStatus').textContent = 'Đã đăng nhập: ' + mst;
    } catch (e) { log('Đăng nhập thất bại: ' + e.message); }
  };

  document.getElementById('invList').onclick = async () => {
    try {
      const from = document.getElementById('invFrom').value.trim();
      const to = document.getElementById('invTo').value.trim();
      const search = `tdlap=ge=${from}T00:00:00;tdlap=le=${to}T23:59:59`;
      const { body } = await api('/api/query/invoices/sold?sort=tdlap:desc&size=15&search=' + encodeURIComponent(search), {
        action: 'Tìm kiếm (hóa đơn)',
        endPoint: '/tra-cuu/tra-cuu-hoa-don'
      });
      log('Danh sách: ' + (Array.isArray(body.datas) ? body.datas.length : '?') + ' hóa đơn');
    } catch (e) { log('Lỗi: ' + e.message); }
  };

  document.getElementById('invDownload').onclick = async () => {
    try {
      const from = document.getElementById('invFrom').value.trim();
      const to = document.getElementById('invTo').value.trim();
      const search = `tdlap=ge=${from}T00:00:00;tdlap=le=${to}T23:59:59`;
      log('Đang tải Excel...');
      const res = await fetch(base + '/api/query/invoices/export-excel?sort=tdlap:desc&search=' + encodeURIComponent(search), {
        credentials: 'include',
        headers: {
          'accept': 'application/json, text/plain, */*',
          'accept-language': 'vi',
          'action': 'Xuất hóa đơn (hóa đơn bán ra)',
          'authorization': 'Bearer ' + token,
          'end-point': '/tra-cuu/tra-cuu-hoa-don',
          'request-id': uuid()
        }
      });
      if (!res.ok) throw new Error(res.status + ' ' + res.statusText);
      const blob = await res.blob();
      const url = URL.createObjectURL(blob);
      const a = document.createElement('a');
      a.href = url; a.download = 'hoa-don.xlsx';
      document.body.appendChild(a); a.click(); a.remove();
      log('Đã tải file Excel');
    } catch (e) { log('Tải thất bại: ' + e.message); }
  };

  log('Bookmarklet sẵn sàng. Đang ở origin: ' + base);
})();
