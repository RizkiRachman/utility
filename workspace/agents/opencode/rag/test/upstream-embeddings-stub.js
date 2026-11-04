'use strict';

/*
 * upstream-embeddings-stub.js — OpenAI-compatible /v1/embeddings stub for the
 * rag test suite. Deterministic 8-dim vectors: for each input text, s = sum of
 * char code points, value[i] = ((s + i) % 7) / 7.
 *
 * Endpoints:
 *   GET  /healthz     -> 200 ok (readiness probe)
 *   GET  /last-auth   -> last seen Authorization header value (default "")
 *   POST /v1/embeddings -> { data: [{ embedding: [8 floats] }, ...] }
 *                         response header x-auth-ok: "true"/"false"
 */

const http = require('node:http');

const PORT = Number(process.env.STUB_PORT || 4599);
let lastAuth = '';

function embed(text) {
  let s = 0;
  for (const ch of String(text)) s += ch.codePointAt(0);
  const vec = [];
  for (let i = 0; i < 8; i++) vec.push(((s + i) % 7) / 7);
  return vec;
}

const server = http.createServer((req, res) => {
  if (req.method === 'GET' && req.url === '/healthz') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end('ok');
    return;
  }
  if (req.method === 'GET' && req.url === '/last-auth') {
    res.writeHead(200, { 'content-type': 'text/plain' });
    res.end(lastAuth);
    return;
  }
  if (req.method === 'POST' && req.url === '/v1/embeddings') {
    lastAuth = String(req.headers.authorization || '');
    let body = '';
    req.on('data', (c) => { body += c; });
    req.on('end', () => {
      let input = [];
      try {
        const parsed = JSON.parse(body);
        if (Array.isArray(parsed.input)) input = parsed.input;
      } catch (e) {
        res.writeHead(400, { 'content-type': 'application/json' });
        res.end(JSON.stringify({ error: { message: 'bad JSON body' } }));
        return;
      }
      const authOk = lastAuth === 'Bearer testkey';
      res.writeHead(200, {
        'content-type': 'application/json',
        'x-auth-ok': String(authOk),
      });
      res.end(JSON.stringify({ data: input.map((t) => ({ embedding: embed(t) })) }));
    });
    return;
  }
  res.writeHead(404, { 'content-type': 'text/plain' });
  res.end('not found');
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`embeddings stub listening on 127.0.0.1:${PORT}`);
});
