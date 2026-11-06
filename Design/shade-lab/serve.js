#!/usr/bin/env node
// Static server for the shade lab (what darkens a zoomed picture under the title and the clock), reachable from the local network.
// POST /choice saves the pick from the page to choice.json next to this file (the last one wins).
// Usage: node serve.js [port]   (default 8773)
const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');

const root = __dirname;
const port = Number(process.argv[2] || process.env.PORT || 8773);
const types = { '.html': 'text/html; charset=utf-8', '.css': 'text/css; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.svg': 'image/svg+xml', '.png': 'image/png', '.jpg': 'image/jpeg', '.json': 'application/json; charset=utf-8' };

http.createServer((req, res) => {
  const url = decodeURIComponent(new URL(req.url, 'http://x').pathname);
  if (req.method === 'POST' && url === '/choice') {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', (chunk) => {
      body += chunk;
      if (body.length > 20000) { res.writeHead(413).end(); req.destroy(); }
    });
    req.on('end', () => {
      let choice;
      try { choice = JSON.parse(body); } catch { res.writeHead(400).end('bad json'); return; }
      const saved = { ...choice, savedAt: new Date().toISOString(), from: req.socket.remoteAddress };
      fs.writeFile(path.join(root, 'choice.json'), JSON.stringify(saved, null, 2) + '\n', (err) => {
        if (err) { res.writeHead(500).end(String(err)); return; }
        console.log('choice saved:', JSON.stringify(saved));
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' }).end(JSON.stringify(saved));
      });
    });
    return;
  }
  const file = path.join(root, url.endsWith('/') ? url + 'index.html' : url);
  if (!file.startsWith(root + path.sep) && file !== root) { res.writeHead(403).end(); return; }
  fs.stat(file, (err, st) => {
    if (err || !st.isFile()) { res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }).end('Not found'); return; }
    res.writeHead(200, { 'Content-Type': types[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-cache' });
    fs.createReadStream(file).pipe(res);
  });
}).listen(port, '0.0.0.0', () => {
  const ips = Object.values(os.networkInterfaces()).flat().filter(a => a && a.family === 'IPv4' && !a.internal).map(a => a.address);
  console.log(`Shade lab: http://localhost:${port}/`);
  ips.forEach(ip => console.log(`In the local network: http://${ip}:${port}/`));
});
