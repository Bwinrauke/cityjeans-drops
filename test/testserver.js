// Test harness only. Serves the app on localhost and proxies Supabase calls
// server-side, so a headless Chromium can exercise the real backend.
const http = require('http');
const https = require('https');
const fs = require('fs');
const path = require('path');

const DIR = __dirname;
const UP = 'nrncccfqgwxcugqdouvs.supabase.co';
const PORT = 8900;

const TYPES = { '.html':'text/html', '.js':'application/javascript', '.css':'text/css', '.png':'image/png' };

http.createServer((req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const p = url.pathname;

  if (p.startsWith('/rest/') || p.startsWith('/auth/') || p.startsWith('/storage/')) {
    const chunks = [];
    req.on('data', c => chunks.push(c));
    req.on('end', () => {
      const body = Buffer.concat(chunks);
      const headers = { ...req.headers, host: UP };
      delete headers['accept-encoding']; delete headers['origin']; delete headers['referer'];
      if (body.length) headers['content-length'] = body.length;
      const up = https.request({ hostname: UP, path: req.url, method: req.method, headers }, r => {
        res.writeHead(r.statusCode, { ...r.headers, 'access-control-allow-origin': '*' });
        r.pipe(res);
      });
      up.on('error', e => { res.writeHead(502); res.end(JSON.stringify({ proxy_error: e.message })); });
      if (body.length) up.write(body);
      up.end();
    });
    return;
  }

  let file = p === '/' ? '/index.html' : p;
  const full = path.join(DIR, path.normalize(file).replace(/^(\.\.[/\\])+/, ''));
  fs.readFile(full, (err, data) => {
    if (err) { res.writeHead(404); return res.end('not found'); }
    let out = data;
    if (/\.html$/.test(full)) {
      out = Buffer.from(data.toString()
        // point the app at this proxy instead of Supabase directly
        .replace(/SUPABASE_URL: "[^"]*"/, 'SUPABASE_URL: "http://localhost:' + PORT + '"')
        // serve the QR libraries locally (the CDN is unreachable from this
        // sandbox). Match the whole tag including any integrity/crossorigin
        // attributes, and keep the local copies byte-identical to the CDN so the
        // SRI hash on the real tag still validates in production.
        .replace(/<script src="https:\/\/cdn\.jsdelivr\.net\/npm\/jsqr@[^"]*"[^>]*><\/script>/, '<script src="/jsQR.js"></script>')
        .replace(/<script src="https:\/\/cdnjs\.cloudflare\.com\/ajax\/libs\/qrcodejs[^"]*"[^>]*><\/script>/, '<script src="/qrcode.min.js"></script>')
        // drop the web-font link so the test does not wait on it
        .replace(/<link href="https:\/\/fonts\.googleapis[^"]*"[^>]*>/, ''));
    }
    if (/config\.js$/.test(full)) {
      out = Buffer.from(data.toString().replace(/SUPABASE_URL: "[^"]*"/, 'SUPABASE_URL: "http://localhost:' + PORT + '"'));
    }
    res.writeHead(200, { 'Content-Type': TYPES[path.extname(full)] || 'text/plain' });
    res.end(out);
  });
}).listen(PORT, () => console.log('test server on ' + PORT));
