'use strict';

/*
 * Zero-dependency upstream stub for portal tests. Mimics the surface of
 * `opencode serve` that the portal proxies to:
 *   GET  /     -> html "UPSTREAM-OK"
 *   GET  /echo -> JSON of the received request headers
 *   GET  /sse  -> text/event-stream, 3 events, then closes
 *   upgrade    -> accepts any websocket handshake (101), closes shortly after
 */

const http = require('node:http');
const crypto = require('node:crypto');

const PORT = Number(process.env.UPSTREAM_PORT || 4096);
const WS_GUID = '258EAFA5-E914-47DA-95CA-C5AB0DC85B11';

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://stub.invalid');
  if (url.pathname === '/echo') {
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify(req.headers, null, 2));
    return;
  }
  if (url.pathname === '/sse') {
    res.writeHead(200, {
      'content-type': 'text/event-stream',
      'cache-control': 'no-cache',
    });
    let n = 0;
    const timer = setInterval(() => {
      n += 1;
      res.write(`event: tick\ndata: event-${n}\n\n`);
      if (n >= 3) {
        clearInterval(timer);
        res.end();
      }
    }, 100);
    res.on('close', () => clearInterval(timer));
    return;
  }
  res.writeHead(200, { 'content-type': 'text/html' });
  res.end('<html><body>UPSTREAM-OK</body></html>');
});

server.on('upgrade', (req, socket) => {
  const key = String(req.headers['sec-websocket-key'] || '');
  const accept = crypto.createHash('sha1').update(key + WS_GUID).digest('base64');
  socket.write(
    'HTTP/1.1 101 Switching Protocols\r\n' +
      'Upgrade: websocket\r\n' +
      'Connection: Upgrade\r\n' +
      `Sec-WebSocket-Accept: ${accept}\r\n` +
      '\r\n',
  );
  // Close shortly after so test clients terminate deterministically.
  const timer = setTimeout(() => socket.destroy(), 3000);
  socket.on('close', () => clearTimeout(timer));
  socket.on('error', () => {
    clearTimeout(timer);
    socket.destroy();
  });
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`[stub] upstream listening on 127.0.0.1:${PORT}`);
});
