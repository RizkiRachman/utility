'use strict';

/*
 * OpenCode Portal: a landing-page reverse proxy in front of `opencode serve`.
 * The user enters the key once; the portal validates it, sets a signed HttpOnly
 * cookie, and injects `Authorization: Basic` on every proxied request, including
 * WebSocket upgrade handshakes. Zero npm dependencies: node core modules only.
 */

const http = require('node:http');
const crypto = require('node:crypto');

// ---------------------------------------------------------------------------
// Configuration (env contract, all optional)
// ---------------------------------------------------------------------------

const UPSTREAM = process.env.PORTAL_UPSTREAM || 'http://127.0.0.1:4096';
const HOST = process.env.PORTAL_HOST || '0.0.0.0';
const PORT = Number(process.env.PORTAL_PORT || 4097);
const USERNAME = process.env.OPENCODE_SERVER_USERNAME || 'opencode';
const PASSWORD = process.env.OPENCODE_SERVER_PASSWORD || '';
const COOKIE_TTL_HOURS = Number(process.env.PORTAL_COOKIE_TTL_HOURS || 168);
const AUTO_LOGIN = /^(1|true|yes)$/i.test(process.env.PORTAL_AUTO_LOGIN || 'false');
const SECURE_COOKIE = /^(1|true|yes)$/i.test(process.env.PORTAL_SECURE_COOKIE || 'false');
const VERBOSE = /^(1|true|yes)$/i.test(process.env.PORTAL_VERBOSE || 'false');
const COOKIE_NAME = 'portal_session';
const LOGIN_PATH = '/portal/login';
const LOGOUT_PATH = '/portal/logout';
const HEALTH_PATH = '/portal/health';
const BODY_LIMIT = 32 * 1024;

const upstreamUrl = new URL(UPSTREAM);

let COOKIE_SECRET = process.env.PORTAL_COOKIE_SECRET || '';
let ephemeralSecret = false;
if (!COOKIE_SECRET) {
  COOKIE_SECRET = crypto.randomBytes(32).toString('hex');
  ephemeralSecret = true;
}

// Headers that must not be forwarded by a proxy (node manages framing itself).
const HOP_BY_HOP = new Set([
  'connection',
  'keep-alive',
  'proxy-authenticate',
  'proxy-authorization',
  'te',
  'trailer',
  'transfer-encoding',
  'upgrade',
]);

// ---------------------------------------------------------------------------
// Cookie session: value = "<expiresMs>.<hmacHex>"
// ---------------------------------------------------------------------------

function sign(expiresMs) {
  return crypto.createHmac('sha256', COOKIE_SECRET).update(String(expiresMs), 'utf8').digest('hex');
}

function makeCookieValue(now = Date.now()) {
  const expiresMs = now + COOKIE_TTL_HOURS * 3600 * 1000;
  return `${expiresMs}.${sign(expiresMs)}`;
}

function verifyCookieValue(value) {
  if (typeof value !== 'string') return false;
  const dot = value.indexOf('.');
  if (dot <= 0) return false;
  const expiresPart = value.slice(0, dot);
  const mac = value.slice(dot + 1);
  if (!/^\d+$/.test(expiresPart) || !/^[0-9a-f]{64}$/.test(mac)) return false;
  const expected = Buffer.from(sign(expiresPart), 'utf8');
  const provided = Buffer.from(mac, 'utf8');
  if (!crypto.timingSafeEqual(expected, provided)) return false;
  return Number(expiresPart) > Date.now();
}

function serializeSessionCookie(value) {
  const parts = [
    `${COOKIE_NAME}=${value}`,
    'HttpOnly',
    'SameSite=Strict',
    'Path=/',
    `Max-Age=${COOKIE_TTL_HOURS * 3600}`,
  ];
  if (SECURE_COOKIE) parts.push('Secure');
  return parts.join('; ');
}

const CLEAR_COOKIE = `${COOKIE_NAME}=; HttpOnly; SameSite=Strict; Path=/; Max-Age=0`;

function getCookie(req, name) {
  const header = req.headers.cookie;
  if (!header) return null;
  const raw = Array.isArray(header) ? header.join('; ') : header;
  for (const part of raw.split(';')) {
    const idx = part.indexOf('=');
    if (idx === -1) continue;
    if (part.slice(0, idx).trim() === name) return part.slice(idx + 1).trim();
  }
  return null;
}

function isAuthed(req) {
  if (AUTO_LOGIN) return true;
  return verifyCookieValue(getCookie(req, COOKIE_NAME));
}

// ---------------------------------------------------------------------------
// Key comparison: hash both sides with SHA256 so timingSafeEqual always gets
// equal-length buffers, then compare in constant time. Works for the empty
// expected key too (only a candidate that is also empty matches).
// ---------------------------------------------------------------------------

function sha256(input) {
  return crypto.createHash('sha256').update(input, 'utf8').digest();
}

function keyMatches(candidate) {
  const provided = sha256(candidate == null ? '' : String(candidate));
  return crypto.timingSafeEqual(sha256(PASSWORD), provided);
}

// ---------------------------------------------------------------------------
// Request body for the portal's own endpoints (login/logout), size-limited.
// ---------------------------------------------------------------------------

function readBody(req, limit = BODY_LIMIT) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (chunk) => {
      size += chunk.length;
      if (size > limit) {
        reject(new Error('body too large'));
        req.destroy();
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

function parseSubmittedKey(body, contentType) {
  if (!body || body.length === 0) return '';
  const text = body.toString('utf8');
  const mime = String(contentType || '').split(';')[0].trim().toLowerCase();
  if (mime === 'application/json') {
    try {
      const parsed = JSON.parse(text);
      if (parsed && typeof parsed.key === 'string') return parsed.key;
      if (parsed && parsed.key != null) return String(parsed.key);
    } catch {
      // fall through to the raw-text fallback
    }
    return '';
  }
  // form-encoded: find key=<value>
  for (const pair of text.split('&')) {
    const idx = pair.indexOf('=');
    const name = idx === -1 ? pair : pair.slice(0, idx);
    let decoded;
    try {
      decoded = decodeURIComponent(name.replace(/\+/g, ' '));
    } catch {
      decoded = name;
    }
    if (decoded === 'key') {
      const value = idx === -1 ? '' : pair.slice(idx + 1);
      try {
        return decodeURIComponent(value.replace(/\+/g, ' '));
      } catch {
        return value;
      }
    }
  }
  return text.trim(); // raw key pasted without form encoding
}

// ---------------------------------------------------------------------------
// Landing page (inline template, no external files, no JS required)
// ---------------------------------------------------------------------------

function escapeHtml(text) {
  return String(text)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function landingPage(errorText = '') {
  const errorBlock = errorText
    ? `\n    <p class="error" role="alert">${escapeHtml(errorText)}</p>`
    : '';
  return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>OpenCode Portal</title>
<style>
  :root { color-scheme: dark; }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100vh; display: grid; place-items: center;
    background: #0d1117; color: #e6edf3;
    font-family: ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace;
  }
  main {
    width: min(24rem, calc(100vw - 2rem)); padding: 2rem;
    border: 1px solid #21262d; border-radius: 8px; background: #161b22;
  }
  h1 { margin: 0 0 0.25rem; font-size: 1.15rem; letter-spacing: 0.02em; }
  .sub { margin: 0 0 1.5rem; font-size: 0.8rem; color: #8b949e; }
  label { display: block; margin-bottom: 0.35rem; font-size: 0.8rem; color: #8b949e; }
  input[type="password"] {
    width: 100%; padding: 0.55rem 0.6rem; font: inherit; color: inherit;
    background: #0d1117; border: 1px solid #30363d; border-radius: 6px; outline: none;
  }
  input[type="password"]:focus { border-color: #58a6ff; }
  button {
    width: 100%; margin-top: 1rem; padding: 0.55rem 0.6rem; font: inherit;
    color: #0d1117; background: #58a6ff; border: 0; border-radius: 6px; cursor: pointer;
  }
  button:hover { filter: brightness(1.1); }
  .error {
    margin: 1rem 0 0; padding: 0.5rem 0.6rem; font-size: 0.78rem;
    color: #f85149; border: 1px solid #f85149; border-radius: 6px;
  }
  footer { margin-top: 1.5rem; font-size: 0.72rem; line-height: 1.6; color: #8b949e; }
  footer code { color: #79c0ff; }
</style>
</head>
<body>
<main>
  <h1>OpenCode Portal</h1>
  <p class="sub">Sign in once. The session lives in an HttpOnly cookie.</p>
  <form method="post" action="${LOGIN_PATH}">
    <label for="key">Key</label>
    <input id="key" name="key" type="password" autofocus autocomplete="current-password">
    <button type="submit">Sign in</button>${errorBlock}
  </form>
  <footer>
    The key is <code>OPENCODE_SERVER_PASSWORD</code> from your <code>.env</code>.<br>
    Set <code>PORTAL_AUTO_LOGIN=true</code> to skip this page entirely.
  </footer>
</main>
</body>
</html>`;
}

// ---------------------------------------------------------------------------
// Proxy helpers
// ---------------------------------------------------------------------------

function joinHeader(value) {
  return Array.isArray(value) ? value.join(', ') : value;
}

function forwardHeaders(req, extra = {}) {
  const headers = {};
  for (const [name, value] of Object.entries(req.headers)) {
    if (HOP_BY_HOP.has(name.toLowerCase())) continue;
    headers[name] = value;
  }
  headers.host = upstreamUrl.host;
  if (headers.cookie != null) {
    const raw = joinHeader(headers.cookie);
    const kept = raw
      .split(';')
      .map((part) => part.trim())
      .filter((part) => part !== '' && part.split('=')[0].trim() !== COOKIE_NAME);
    if (kept.length > 0) headers.cookie = kept.join('; ');
    else delete headers.cookie;
  }
  if (PASSWORD) {
    const token = Buffer.from(`${USERNAME}:${PASSWORD}`, 'utf8').toString('base64');
    headers.authorization = `Basic ${token}`;
  } else {
    delete headers.authorization;
  }
  Object.assign(headers, extra);
  return headers;
}

function upstreamOptions(method, path, headers) {
  return {
    protocol: upstreamUrl.protocol,
    hostname: upstreamUrl.hostname,
    port: upstreamUrl.port || (upstreamUrl.protocol === 'https:' ? 443 : 80),
    method,
    path,
    headers,
  };
}

function send502(res, message) {
  if (res.headersSent) {
    res.destroy();
    return;
  }
  res.writeHead(502, { 'content-type': 'text/plain; charset=utf-8' });
  res.end(`portal: upstream unreachable (${message})`);
}

function proxyRequest(req, res) {
  const upstreamReq = http.request(
    upstreamOptions(req.method, req.url, forwardHeaders(req)),
    (upstreamRes) => {
      const outHeaders = {};
      for (const [name, value] of Object.entries(upstreamRes.headers)) {
        const lower = name.toLowerCase();
        if (lower === 'connection' || lower === 'keep-alive' || lower === 'transfer-encoding') continue;
        outHeaders[name] = value;
      }
      res.writeHead(upstreamRes.statusCode || 502, outHeaders);
      // Manual piping keeps SSE and other streaming responses unbuffered, and
      // lets us append upstream trailers before ending the client response.
      upstreamRes.on('data', (chunk) => res.write(chunk));
      upstreamRes.on('end', () => {
        const trailers = upstreamRes.trailers;
        if (trailers && Object.keys(trailers).length > 0) res.addTrailers(trailers);
        res.end();
      });
      upstreamRes.on('error', () => res.destroy());
      if (VERBOSE) console.log(`[portal] ${req.method} ${req.url} -> ${upstreamRes.statusCode}`);
    },
  );
  upstreamReq.on('error', (err) => {
    console.error(`[portal] upstream error for ${req.method} ${req.url}: ${err.message}`);
    send502(res, err.message);
  });
  res.on('close', () => {
    if (!upstreamReq.destroyed && !res.writableEnded) upstreamReq.destroy();
  });
  req.pipe(upstreamReq);
}

// ---------------------------------------------------------------------------
// Portal's own endpoints
// ---------------------------------------------------------------------------

function respondJson(res, statusCode, payload) {
  res.writeHead(statusCode, { 'content-type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify(payload));
}

function isJsonClient(req) {
  const accept = String(req.headers.accept || '');
  return accept.toLowerCase().includes('application/json');
}

async function handleLogin(req, res) {
  let body;
  try {
    body = await readBody(req);
  } catch {
    res.writeHead(413, { 'content-type': 'text/plain; charset=utf-8' });
    res.end('portal: payload too large');
    return;
  }
  if (keyMatches(parseSubmittedKey(body, req.headers['content-type']))) {
    res.writeHead(303, {
      'set-cookie': serializeSessionCookie(makeCookieValue()),
      location: '/',
    });
    res.end();
    return;
  }
  res.writeHead(401, { 'content-type': 'text/html; charset=utf-8' });
  res.end(landingPage('Invalid key. Check OPENCODE_SERVER_PASSWORD in your .env.'));
}

function probeUpstream() {
  return new Promise((resolve) => {
    const req = http.request(
      upstreamOptions('GET', '/', { host: upstreamUrl.host }),
      (res) => {
        res.resume();
        resolve(res.statusCode != null);
      },
    );
    req.setTimeout(1000, () => {
      req.destroy();
      resolve(false);
    });
    req.on('error', () => resolve(false));
    req.end();
  });
}

async function handleHealth(req, res) {
  const upstream = await probeUpstream();
  respondJson(res, 200, { ok: true, upstream });
}

function wantsJsonOrApi(req, pathname) {
  return pathname.startsWith('/api') || isJsonClient(req);
}

const server = http.createServer((req, res) => {
  const url = new URL(req.url, 'http://portal.invalid');
  const pathname = url.pathname;

  if (pathname === LOGIN_PATH && req.method === 'POST') {
    handleLogin(req, res);
    return;
  }
  if (pathname === LOGOUT_PATH && req.method === 'POST') {
    res.writeHead(303, { 'set-cookie': CLEAR_COOKIE, location: '/' });
    res.end();
    return;
  }
  if (pathname === HEALTH_PATH && (req.method === 'GET' || req.method === 'HEAD')) {
    if (!isAuthed(req)) {
      if (wantsJsonOrApi(req, pathname)) respondJson(res, 401, { error: 'unauthorized' });
      else {
        res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
        res.end(landingPage());
      }
      return;
    }
    handleHealth(req, res);
    return;
  }

  if (isAuthed(req)) {
    proxyRequest(req, res);
    return;
  }
  if (wantsJsonOrApi(req, pathname)) {
    respondJson(res, 401, { error: 'unauthorized' });
    return;
  }
  const errorText = url.searchParams.get('error') === '1' ? 'Session missing, invalid, or expired. Sign in again.' : '';
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end(landingPage(errorText));
});

// ---------------------------------------------------------------------------
// WebSocket (and any other) upgrade handling
// ---------------------------------------------------------------------------

server.on('upgrade', (req, socket, head) => {
  if (!isAuthed(req)) {
    socket.write('HTTP/1.1 401 Unauthorized\r\nconnection: close\r\ncontent-length: 0\r\n\r\n');
    socket.destroy();
    return;
  }
  const headers = forwardHeaders(req, {
    connection: 'Upgrade',
    upgrade: req.headers.upgrade || 'websocket',
  });
  const upgradeReq = http.request(upstreamOptions(req.method, req.url, headers));
  upgradeReq.on('upgrade', (upstreamRes, upstreamSocket, upstreamHead) => {
    let responseText = `HTTP/1.1 ${upstreamRes.statusCode} ${upstreamRes.statusMessage || 'Switching Protocols'}\r\n`;
    for (let i = 0; i < upstreamRes.rawHeaders.length; i += 2) {
      const name = upstreamRes.rawHeaders[i];
      const lower = name.toLowerCase();
      if (lower === 'transfer-encoding' || lower === 'content-length') continue;
      responseText += `${name}: ${upstreamRes.rawHeaders[i + 1]}\r\n`;
    }
    socket.write(`${responseText}\r\n`);
    if (upstreamHead && upstreamHead.length > 0) socket.write(upstreamHead);
    if (head && head.length > 0) upstreamSocket.write(head);
    upstreamSocket.pipe(socket);
    socket.pipe(upstreamSocket);
    const closeBoth = () => {
      socket.destroy();
      upstreamSocket.destroy();
    };
    socket.on('error', closeBoth);
    upstreamSocket.on('error', closeBoth);
    socket.on('close', closeBoth);
    upstreamSocket.on('close', closeBoth);
  });
  upgradeReq.on('response', (upstreamRes) => {
    // Upstream refused the upgrade (401, 404, ...): destroy both sockets.
    upstreamRes.resume();
    socket.destroy();
    upgradeReq.destroy();
  });
  upgradeReq.on('error', () => socket.destroy());
  upgradeReq.end();
});

// ---------------------------------------------------------------------------
// Boot
// ---------------------------------------------------------------------------

server.listen(PORT, HOST, () => {
  console.log(
    `[portal] listening on ${HOST}:${PORT} -> upstream ${UPSTREAM} | ` +
      `auth-injection=${PASSWORD ? 'on' : 'off'} | auto-login=${AUTO_LOGIN ? 'on' : 'off'}` +
      (ephemeralSecret
        ? ' | random cookie secret generated; sessions reset on restart (set PORTAL_COOKIE_SECRET for stable sessions)'
        : ''),
  );
});
