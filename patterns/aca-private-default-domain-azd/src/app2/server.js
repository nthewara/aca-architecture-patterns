const http = require('http');
const APP = process.env.APP_NAME || 'app';
const port = process.env.PORT || 80;
http.createServer((req, res) => {
  if (req.url === '/healthz') { res.writeHead(200); return res.end('ok'); }
  res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
  res.end(`<!doctype html><html><head><meta charset="utf-8"><title>${APP}</title>
<style>body{font-family:system-ui,sans-serif;background:#0b1020;color:#e6ecff;display:grid;place-items:center;height:100vh;margin:0}
.card{padding:2rem 3rem;border:1px solid #2a3a6a;border-radius:16px;background:#121a33;text-align:center}
h1{margin:0 0 .5rem;font-size:2.4rem}code{color:#7fd1ff}</style></head>
<body><div class="card"><h1>👋 ${APP}</h1>
<p>Served by <strong>${APP}</strong> via internal ACA ingress on the environment default domain.</p>
<p>host header: <code>${req.headers.host || '-'}</code></p></div></body></html>`);
}).listen(port, () => console.log(`${APP} listening on ${port}`));
