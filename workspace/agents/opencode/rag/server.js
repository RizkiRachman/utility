'use strict';

/*
 * rag — Retrieval-Augmented Generation MCP server for the opencode workspace.
 * Zero npm dependencies: node core modules only (node:sqlite, node:http via
 * global fetch, node:crypto, node:fs, node:path, node:os).
 *
 * Chunking is language aware where it is cheap: markdown splits on headings,
 * Java splits on method boundaries (brace depth, headings carry
 * package > class > method), everything else splits on paragraph breaks.
 * Build output directories (target/, build/, .gradle/, ...), lockfiles, and
 * common binary extensions are excluded from the walk.
 *
 * Dual mode:
 *   CLI  — `node server.js index [root] | search <q> [--k N] [--glob P] | status | get <id>`
 *   MCP  — no args: JSON-RPC 2.0 over stdio (newline-delimited). Only JSON-RPC
 *          messages go to stdout; all diagnostics go to stderr.
 *
 * Storage: SQLite (node:sqlite, WAL) with FTS5 for keyword ranking plus
 * Float32 vectors for cosine similarity. Embeddings default to deterministic
 * local hashed n-gram vectors (fully offline); set RAG_EMBEDDINGS_URL and
 * RAG_EMBEDDINGS_MODEL to upgrade to an OpenAI-compatible /v1/embeddings
 * endpoint.
 */

// Attach a warning listener BEFORE loading node:sqlite so the
// ExperimentalWarning is captured instead of printed to stderr.
process.on('warning', (w) => {
  if (w && w.name === 'ExperimentalWarning') return;
  console.error(w && w.stack ? w.stack : String(w));
});

const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const crypto = require('node:crypto');
const { DatabaseSync } = require('node:sqlite');

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

const SERVER_NAME = 'rag';
const SERVER_VERSION = '1.0.0';
const DEFAULT_ROOT = '/home/node/workspace';
const DEFAULT_DB = path.join(os.homedir(), '.local/share/opencode/rag/rag.db');
const MAX_FILE_SIZE = 512 * 1024;
const CHUNK_TARGET = 1200;   // chars per chunk (paragraph accumulation)
const CHUNK_OVERLAP = 150;   // chars carried into the next chunk
const CHUNK_HARD_SPLIT = 4000; // single paragraph above this gets windowed
const JAVA_CHUNK_MIN = 400;   // closed member below this merges into the next chunk
const JAVA_CHUNK_HARD = 1400; // java chunk above this is split at the next line
const LOCAL_DIMS = 256;      // hashed n-gram vector width
const EMBED_BATCH = 32;      // max texts per remote embeddings request
const FTS_TOP = 50;          // fts rows joined into the candidate set
const FTS_TOP_LARGE = 200;   // fts rows when the corpus is too big to scan
const FULL_SCAN_LIMIT = 2000; // full vector scan below this chunk count
const FUSE_KEYWORD = 0.6;    // bm25 rank weight
const FUSE_VECTOR = 0.4;     // cosine weight
const SNIPPET_CHARS = 200;
const SKIP_DIRS = new Set([
  '.git', 'node_modules', '__pycache__', '.next', 'dist',
  'pre-install', 'session', '.session', '.venv',
  // Java / JVM build outputs and IDE metadata
  'target', 'build', '.gradle', '.mvn', 'out', '.settings', '.idea', 'bin',
  '.classpath',
]);
// Exact filename matches: dependency lockfiles and OS metadata never index.
const NAME_SKIPS = new Set([
  'package-lock.json', 'yarn.lock', 'pnpm-lock.yaml', 'gradle.lockfile',
  '.DS_Store', 'Thumbs.db',
]);
// Extensions that are never worth indexing even when they decode as text.
// Checked after the null-byte binary sniff, so genuinely binary formats
// still count as skipped_binary. svg stays indexed (it is text).
const EXT_SKIPS = new Set([
  'jar', 'war', 'zip', 'tar', 'gz', 'tgz', '7z', 'rar',
  'class', 'exe', 'dll', 'so', 'dylib', 'a', 'o', 'obj',
  'png', 'jpg', 'jpeg', 'gif', 'ico',
  'pdf', 'doc', 'docx', 'xls', 'xlsx', 'ppt', 'pptx',
  'woff', 'woff2', 'ttf', 'eot', 'otf',
  'mp3', 'mp4', 'mov', 'avi',
  'sqlite', 'db', 'wasm', 'node', 'pyc', 'pyo', 'bin', 'iso', 'img',
]);

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

function logErr(msg) {
  console.error(`[rag] ${msg}`);
}

function tokenize(text) {
  return String(text || '').toLowerCase().split(/[^a-z0-9]+/).filter(Boolean);
}

function fnv1a(str) {
  let h = 0x811c9dc5;
  for (let i = 0; i < str.length; i++) {
    h ^= str.charCodeAt(i);
    h = Math.imul(h, 0x01000193);
  }
  return h >>> 0;
}

function sha256(buf) {
  return crypto.createHash('sha256').update(buf).digest('hex');
}

function expandTilde(p) {
  if (p === '~') return os.homedir();
  if (p.startsWith('~/')) return path.join(os.homedir(), p.slice(2));
  return p;
}

function nowIso(epoch) {
  const ms = epoch === undefined ? Date.now() : epoch;
  return new Date(ms).toISOString();
}

function snippetOf(text) {
  return String(text || '').replace(/\s+/g, ' ').trim().slice(0, SNIPPET_CHARS);
}

/**
 * Simple glob matcher supporting * (within a path segment), ** (across
 * segments) and ? (single character). Anchored on the whole relative path.
 */
function globToRegExp(pattern) {
  let re = '^';
  for (let i = 0; i < pattern.length; i++) {
    const c = pattern[i];
    if (c === '*') {
      if (pattern[i + 1] === '*') { re += '.*'; i++; } else { re += '[^/]*'; }
    } else if (c === '?') {
      re += '[^/]';
    } else {
      re += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
    }
  }
  return new RegExp(re + '$');
}

// ---------------------------------------------------------------------------
// Embeddings
// ---------------------------------------------------------------------------

/**
 * Local deterministic hashed n-gram embedding: word unigrams + bigrams plus
 * char 4-grams of each boundary-padded word, hashed into D buckets with
 * fnv1a, L2 normalized. No I/O, stable across runs and machines.
 */
function localEmbed(text, dims) {
  const vec = new Float32Array(dims);
  const tokens = tokenize(text);
  const feats = [];
  for (let i = 0; i < tokens.length; i++) {
    const w = tokens[i];
    feats.push(w);
    if (i + 1 < tokens.length) feats.push(`${w}_${tokens[i + 1]}`);
    const padded = `#${w}#`;
    for (let j = 0; j + 4 <= padded.length; j++) feats.push(padded.slice(j, j + 4));
  }
  for (const f of feats) vec[fnv1a(f) % dims] += 1;
  let norm = 0;
  for (let i = 0; i < dims; i++) norm += vec[i] * vec[i];
  norm = Math.sqrt(norm);
  if (norm > 0) for (let i = 0; i < dims; i++) vec[i] /= norm;
  return vec;
}

function embeddingsConfig() {
  const url = process.env.RAG_EMBEDDINGS_URL;
  const model = process.env.RAG_EMBEDDINGS_MODEL;
  if (!url || !model) return null;
  return { url, model, key: process.env.RAG_EMBEDDINGS_KEY || '' };
}

async function embedBatchRemote(texts, cfg) {
  const res = await fetch(cfg.url, {
    method: 'POST',
    headers: {
      'content-type': 'application/json',
      authorization: `Bearer ${cfg.key}`,
    },
    body: JSON.stringify({ model: cfg.model, input: texts }),
    signal: AbortSignal.timeout(30000),
  });
  if (!res.ok) throw new Error(`embeddings endpoint returned HTTP ${res.status}`);
  const body = await res.json();
  const data = body && body.data;
  if (!Array.isArray(data) || data.length !== texts.length) {
    throw new Error('embeddings endpoint returned an unexpected shape');
  }
  return data.map((d) => {
    if (!Array.isArray(d.embedding) || d.embedding.length === 0) {
      throw new Error('embeddings endpoint returned an empty embedding');
    }
    return Float32Array.from(d.embedding);
  });
}

/** Embed all texts remotely, sequentially in batches of EMBED_BATCH. */
async function embedAllRemote(texts, cfg) {
  const out = [];
  for (let i = 0; i < texts.length; i += EMBED_BATCH) {
    const batch = texts.slice(i, i + EMBED_BATCH);
    out.push(...await embedBatchRemote(batch, cfg));
  }
  return out;
}

async function embedQueryRemote(text, cfg) {
  const [vec] = await embedBatchRemote([text], cfg);
  return vec;
}

function vecToBlob(vec) {
  return Buffer.from(vec.buffer, vec.byteOffset, vec.byteLength);
}

function blobToVec(buf) {
  const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
  return new Float32Array(ab);
}

function cosine(a, b) {
  let dot = 0;
  let na = 0;
  let nb = 0;
  const n = Math.min(a.length, b.length);
  for (let i = 0; i < n; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  if (na === 0 || nb === 0) return 0;
  return dot / Math.sqrt(na * nb);
}

// ---------------------------------------------------------------------------
// Chunking
// ---------------------------------------------------------------------------

/**
 * Windowed hard split for oversized single paragraphs: ~CHUNK_TARGET char
 * windows with CHUNK_OVERLAP char overlap, cutting at whitespace when close
 * to the window edge.
 */
function splitLongParagraph(text, startLine) {
  const out = [];
  let pos = 0;
  let line = startLine;
  while (pos < text.length) {
    let end = Math.min(pos + CHUNK_TARGET, text.length);
    if (end < text.length) {
      const cut = text.lastIndexOf(' ', end);
      if (cut > pos + CHUNK_TARGET - 200) end = cut;
    }
    const slice = text.slice(pos, end);
    const nl = (slice.match(/\n/g) || []).length;
    out.push({ text: slice, startLine: line, endLine: line + nl });
    line += nl;
    if (end >= text.length) break;
    const next = end - CHUNK_OVERLAP;
    pos = next > pos ? next : end;
  }
  return out;
}

/** Split plain text / code on blank-line boundaries, ~1200 chars, ~150 overlap. */
function chunkPlainText(text) {
  const paras = [];
  let cur = null;
  const lines = text.split('\n');
  lines.forEach((ln, i) => {
    const n = i + 1;
    if (ln.trim() === '') {
      if (cur) { paras.push(cur); cur = null; }
    } else {
      if (!cur) cur = { startLine: n, lines: [] };
      cur.lines.push(ln);
      cur.endLine = n;
    }
  });
  if (cur) paras.push(cur);
  for (const p of paras) p.text = p.lines.join('\n');

  const chunks = [];
  let acc = [];
  let accLen = 0;
  const flush = () => {
    if (!acc.length) return;
    chunks.push({
      text: acc.map((a) => a.text).join('\n'),
      startLine: acc[0].startLine,
      endLine: acc[acc.length - 1].endLine,
    });
  };
  for (const p of paras) {
    if (p.text.length > CHUNK_HARD_SPLIT) {
      if (acc.length) { flush(); acc = []; accLen = 0; }
      chunks.push(...splitLongParagraph(p.text, p.startLine));
      continue;
    }
    if (accLen + p.text.length > CHUNK_TARGET && accLen > 0) {
      flush();
      const tail = [];
      let tlen = 0;
      for (let j = acc.length - 1; j >= 0; j--) {
        if (tlen + acc[j].text.length > CHUNK_OVERLAP && tail.length) break;
        tail.unshift(acc[j]);
        tlen += acc[j].text.length + 1;
      }
      acc = tail;
      accLen = tlen;
    }
    acc.push(p);
    accLen += p.text.length + 1;
  }
  flush();
  return chunks;
}

/** Split markdown on headings, keeping the heading path per chunk. */
function chunkMarkdown(text) {
  const lines = text.split('\n');
  const stack = []; // { level, title }
  let cur = { startLine: 1, lines: [] };
  const sections = [];

  lines.forEach((ln, i) => {
    const n = i + 1;
    const m = /^(#{1,6})\s+(.*?)\s*#*\s*$/.exec(ln);
    if (m) {
      sections.push({
        heading: stack.map((s) => s.title).join(' > '),
        startLine: cur.startLine,
        lines: cur.lines,
      });
      const level = m[1].length;
      const title = m[2].trim();
      while (stack.length && stack[stack.length - 1].level >= level) stack.pop();
      stack.push({ level, title });
      cur = { startLine: n, lines: [ln] };
    } else {
      cur.lines.push(ln);
    }
  });
  sections.push({
    heading: stack.map((s) => s.title).join(' > '),
    startLine: cur.startLine,
    lines: cur.lines,
  });

  const out = [];
  for (const s of sections) {
    const body = s.lines.join('\n');
    if (!body.trim()) continue;
    if (body.length > CHUNK_HARD_SPLIT) {
      for (const piece of splitLongParagraph(body, s.startLine)) {
        out.push({ heading: s.heading, ...piece });
      }
    } else {
      out.push({
        heading: s.heading,
        text: body,
        startLine: s.startLine,
        endLine: s.startLine + s.lines.length - 1,
      });
    }
  }
  return out;
}

function isMarkdown(relPath) {
  return /\.(md|markdown)$/i.test(relPath);
}

function isJava(relPath) {
  return /\.java$/i.test(relPath);
}

/**
 * Split Java source on member boundaries using brace depth. Naive scan:
 * braces are counted outside line comments, string literals, and char
 * literals; block comments are not tracked. A chunk closes when depth
 * returns to the class-body level (1) and JAVA_CHUNK_MIN chars have
 * accumulated; any chunk above JAVA_CHUNK_HARD chars is hard split at the
 * next line boundary. Headings carry package > class > method context
 * (best effort: constructors use the class name, unparseable files fall
 * back to chunkPlainText). Chunk text is always a raw slice of the file;
 * the heading is metadata only, same as markdown.
 */
function chunkJava(text, relPath) {
  const lines = text.split('\n');
  const base = path.basename(relPath || '').replace(/\.java$/i, '') || 'file';
  const memberRe = /([A-Za-z_$][A-Za-z0-9_$]*)\s*\(/g;
  let pkg = '';
  let cls = '';
  let method = '';
  let depth = 0;
  let sawDepth = false;
  const chunks = [];
  let cur = null; // { startLine, lines, heading, members, len }

  const headingNow = () => {
    const parts = [];
    if (pkg) parts.push(`package ${pkg};`);
    parts.push(cls || base);
    if (method) parts.push(method);
    return parts.join(' > ');
  };

  const flush = () => {
    if (!cur) return;
    const body = cur.lines.join('\n');
    if (body.trim()) {
      chunks.push({
        heading: cur.heading,
        text: body,
        startLine: cur.startLine,
        endLine: cur.startLine + cur.lines.length - 1,
      });
    }
    cur = null;
  };

  for (let i = 0; i < lines.length; i++) {
    const ln = lines[i];
    const n = i + 1;

    // Scan the line: brace depth plus package/class/method context.
    let inStr = false;
    let inChr = false;
    let inComment = false;
    let enteredMember = false; // depth crossed 1 -> 2 (a member body opened)
    let leftMember = false;    // depth returned to 1 (a member body closed)
    for (let j = 0; j < ln.length; j++) {
      const c = ln[j];
      if (inComment) break;
      if (inStr) {
        if (c === '\\') j++;
        else if (c === '"') inStr = false;
        continue;
      }
      if (inChr) {
        if (c === '\\') j++;
        else if (c === "'") inChr = false;
        continue;
      }
      if (c === '/' && ln[j + 1] === '/') { inComment = true; continue; }
      if (c === '"') { inStr = true; continue; }
      if (c === "'") { inChr = true; continue; }
      if (c === '{') {
        depth++;
        sawDepth = true;
        if (depth === 2) enteredMember = true;
      } else if (c === '}') {
        if (depth > 0) depth--;
        if (depth === 1) leftMember = true;
      }
    }
    if (!pkg) {
      const pm = /^\s*package\s+([\w.]+)\s*;/.exec(ln);
      if (pm) pkg = pm[1];
    }
    if (!cls) {
      const cm = /^\s*(?:@\w+\s+)*(?:public\s+|protected\s+|private\s+|abstract\s+|final\s+|sealed\s+|static\s+)*(?:class|interface|enum|record)\s+([A-Za-z_$][A-Za-z0-9_$]*)/.exec(ln);
      if (cm) cls = cm[1];
    }
    if (enteredMember) {
      // The method name is the last identifier followed by "(" in the
      // lines accumulated since the previous member closed.
      const buf = cur ? cur.lines.concat(ln).join('\n') : ln;
      let m;
      let last = null;
      memberRe.lastIndex = 0;
      while ((m = memberRe.exec(buf))) last = m[1];
      if (last) method = last;
    }

    if (!cur) cur = { startLine: n, lines: [], heading: headingNow(), members: 0, len: 0 };
    if (enteredMember) {
      cur.members++;
      if (cur.members === 1) cur.heading = headingNow();
    }
    cur.lines.push(ln);
    cur.len += ln.length + 1;

    if ((leftMember && cur.len >= JAVA_CHUNK_MIN) || cur.len > JAVA_CHUNK_HARD) flush();
  }
  flush();

  if (!sawDepth) return chunkPlainText(text);
  return chunks;
}

// ---------------------------------------------------------------------------
// Database
// ---------------------------------------------------------------------------

function openDb(dbPathRaw) {
  const dbPath = expandTilde(dbPathRaw);
  fs.mkdirSync(path.dirname(dbPath), { recursive: true });
  const db = new DatabaseSync(dbPath);
  db.exec('PRAGMA journal_mode = WAL');
  db.exec(`
    CREATE TABLE IF NOT EXISTS files (
      id INTEGER PRIMARY KEY,
      path TEXT UNIQUE,
      hash TEXT,
      size INTEGER,
      mtime INTEGER,
      indexed_at INTEGER
    );
    CREATE TABLE IF NOT EXISTS chunks (
      id INTEGER PRIMARY KEY,
      file_id INTEGER,
      ordinal INTEGER,
      heading TEXT,
      start_line INTEGER,
      end_line INTEGER,
      text TEXT
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS fts USING fts5(
      text, chunk_id UNINDEXED, tokenize='porter unicode61'
    );
    CREATE TABLE IF NOT EXISTS vectors (
      chunk_id INTEGER PRIMARY KEY,
      blob BLOB
    );
    CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT);
  `);
  return db;
}

function metaGet(db, key) {
  const row = db.prepare('SELECT value FROM meta WHERE key = ?').get(key);
  return row ? row.value : null;
}

function metaSet(db, key, value) {
  db.prepare('INSERT OR REPLACE INTO meta (key, value) VALUES (?, ?)').run(key, String(value));
}

// ---------------------------------------------------------------------------
// Filesystem walk
// ---------------------------------------------------------------------------

function walk(root, skipStats) {
  const out = [];
  const visit = (dir) => {
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (e) {
      logErr(`cannot read ${dir}: ${e.message}`);
      return;
    }
    entries.sort((a, b) => a.name.localeCompare(b.name));
    for (const ent of entries) {
      const abs = path.join(dir, ent.name);
      if (ent.isDirectory()) {
        if (!SKIP_DIRS.has(ent.name)) visit(abs);
        continue;
      }
      if (!ent.isFile()) continue;
      if (NAME_SKIPS.has(ent.name)) {
        if (skipStats) skipStats.skipped_name++;
        continue;
      }
      out.push({ abs, rel: path.relative(root, abs).split(path.sep).join('/') });
    }
  };
  visit(root);
  return out;
}

function loadFile(abs, relPath) {
  const st = fs.statSync(abs);
  if (st.size > MAX_FILE_SIZE) return { skip: 'size', size: st.size, mtime: st.mtimeMs };
  const buf = fs.readFileSync(abs);
  if (buf.includes(0)) return { skip: 'binary', size: st.size, mtime: st.mtimeMs };
  const ext = path.extname(relPath || abs).slice(1).toLowerCase();
  if (EXT_SKIPS.has(ext)) return { skip: 'extension', size: st.size, mtime: st.mtimeMs };
  return { skip: null, buf, size: st.size, mtime: st.mtimeMs };
}

// ---------------------------------------------------------------------------
// Indexing
// ---------------------------------------------------------------------------

function deleteChunksOfFiles(db, fileIds) {
  if (!fileIds.length) return;
  const placeholders = fileIds.map(() => '?').join(',');
  const ids = db.prepare(
    `SELECT id FROM chunks WHERE file_id IN (${placeholders})`
  ).all(...fileIds);
  if (ids.length) {
    const ph = ids.map(() => '?').join(',');
    const arg = ids.map((r) => r.id);
    db.prepare(`DELETE FROM fts WHERE chunk_id IN (${ph})`).run(...arg);
    db.prepare(`DELETE FROM vectors WHERE chunk_id IN (${ph})`).run(...arg);
  }
  db.prepare(`DELETE FROM chunks WHERE file_id IN (${placeholders})`).run(...fileIds);
}

/**
 * Incremental index of root into the database.
 * Returns stats: { files, rechunked, purged, skipped_binary, skipped_ext,
 * skipped_name, chunks, dims, mode, ms }.
 */
async function indexRoot(db, rootRaw) {
  const t0 = Date.now();
  const root = path.resolve(expandTilde(rootRaw));
  if (!fs.existsSync(root) || !fs.statSync(root).isDirectory()) {
    throw new Error(`root is not a directory: ${root}`);
  }
  const cfg = embeddingsConfig();
  const stats = {
    root, files: 0, rechunked: 0, purged: 0, skipped_binary: 0,
    skipped_ext: 0, skipped_name: 0,
    chunks: 0, dims: null, mode: null, ms: 0,
  };

  const disk = walk(root, stats);
  const diskByPath = new Map(disk.map((f) => [f.abs, f]));
  const existing = db.prepare('SELECT id, path, hash FROM files').all();
  const existingByPath = new Map(existing.map((r) => [r.path, r]));

  // Files deleted on disk: purge chunks + fts + vectors + file row.
  const purgedIds = existing.filter((r) => !diskByPath.has(r.path)).map((r) => r.id);
  if (purgedIds.length) {
    db.exec('BEGIN');
    try {
      deleteChunksOfFiles(db, purgedIds);
      const del = db.prepare('DELETE FROM files WHERE id = ?');
      for (const id of purgedIds) del.run(id);
      db.exec('COMMIT');
    } catch (e) {
      db.exec('ROLLBACK');
      throw e;
    }
    stats.purged = purgedIds.length;
  }

  // Pending vectors for newly created chunks (filled during re-chunk).
  let pending = [];

  for (const f of disk) {
    const loaded = loadFile(f.abs, f.rel);
    if (loaded.skip === 'binary') { stats.skipped_binary++; continue; }
    if (loaded.skip === 'extension') { stats.skipped_ext++; continue; }
    if (loaded.skip === 'size') continue;
    const hash = sha256(loaded.buf);
    const prev = existingByPath.get(f.abs);
    if (prev && prev.hash === hash) continue; // unchanged: skip
    stats.rechunked++;

    const text = loaded.buf.toString('utf8');
    const pieces = isJava(f.rel)
      ? chunkJava(text, f.rel)
      : isMarkdown(f.rel) ? chunkMarkdown(text) : chunkPlainText(text);

    db.exec('BEGIN');
    try {
      let fileId;
      if (prev) {
        deleteChunksOfFiles(db, [prev.id]);
        db.prepare('UPDATE files SET hash=?, size=?, mtime=?, indexed_at=? WHERE id=?')
          .run(hash, loaded.size, Math.round(loaded.mtime), Date.now(), prev.id);
        fileId = prev.id;
      } else {
        const ins = db.prepare(
          'INSERT INTO files (path, hash, size, mtime, indexed_at) VALUES (?, ?, ?, ?, ?)'
        ).run(f.abs, hash, loaded.size, Math.round(loaded.mtime), Date.now());
        fileId = Number(ins.lastInsertRowid);
      }
      const insChunk = db.prepare(
        'INSERT INTO chunks (file_id, ordinal, heading, start_line, end_line, text) VALUES (?, ?, ?, ?, ?, ?)'
      );
      const insFts = db.prepare('INSERT INTO fts (text, chunk_id) VALUES (?, ?)');
      for (let i = 0; i < pieces.length; i++) {
        const p = pieces[i];
        const r = insChunk.run(fileId, i, p.heading || '', p.startLine, p.endLine, p.text);
        const chunkId = Number(r.lastInsertRowid);
        insFts.run(p.text, chunkId);
        pending.push({ id: chunkId, text: p.text });
      }
      db.exec('COMMIT');
    } catch (e) {
      db.exec('ROLLBACK');
      throw e;
    }
  }

  // --- Embedding pass -----------------------------------------------------
  let mode = cfg ? 'remote' : 'local';
  const prevDims = metaGet(db, 'dims');
  let dims = cfg ? null : LOCAL_DIMS;

  if (cfg && pending.length) {
    try {
      logErr(`remote embeddings: ${pending.length} texts via ${cfg.url}`);
      let vectors = await embedAllRemote(pending.map((p) => p.text), cfg);
      dims = vectors[0].length;
      if (prevDims && Number(prevDims) !== dims) {
        // Dimensionality changed: rebuild every vector, not just new chunks.
        logErr(`dims changed ${prevDims} -> ${dims}; rebuilding all vectors`);
        db.exec('DELETE FROM vectors');
        const all = db.prepare('SELECT id, text FROM chunks ORDER BY id').all();
        pending = all.map((r) => ({ id: r.id, text: r.text }));
        vectors = await embedAllRemote(pending.map((p) => p.text), cfg);
        dims = vectors[0].length;
      }
      const put = db.prepare('INSERT OR REPLACE INTO vectors (chunk_id, blob) VALUES (?, ?)');
      db.exec('BEGIN');
      for (let i = 0; i < pending.length; i++) put.run(pending[i].id, vecToBlob(vectors[i]));
      db.exec('COMMIT');
    } catch (e) {
      // Fall back to local for this run: wipe stale vectors and rebuild all.
      logErr(`remote embeddings failed (${e.message}); falling back to local for this run`);
      mode = 'local';
      dims = LOCAL_DIMS;
      db.exec('DELETE FROM vectors');
      const all = db.prepare('SELECT id, text FROM chunks ORDER BY id').all();
      pending = all.map((r) => ({ id: r.id, text: r.text }));
    }
  } else if (!cfg) {
    if (prevDims && Number(prevDims) !== LOCAL_DIMS) {
      db.exec('DELETE FROM vectors');
      const all = db.prepare('SELECT id, text FROM chunks ORDER BY id').all();
      pending = all.map((r) => ({ id: r.id, text: r.text }));
    }
  }

  if (mode === 'local' && pending.length) {
    const put = db.prepare('INSERT OR REPLACE INTO vectors (chunk_id, blob) VALUES (?, ?)');
    db.exec('BEGIN');
    for (const p of pending) put.run(p.id, vecToBlob(localEmbed(p.text, LOCAL_DIMS)));
    db.exec('COMMIT');
    dims = LOCAL_DIMS;
  }

  stats.files = db.prepare('SELECT COUNT(*) AS n FROM files').get().n;
  stats.chunks = db.prepare('SELECT COUNT(*) AS n FROM chunks').get().n;
  // Only overwrite dims/mode when this run actually (re)embedded something;
  // otherwise the meta keeps describing the vectors that are already stored.
  if (pending.length > 0) {
    metaSet(db, 'dims', dims);
    metaSet(db, 'embedding_mode', mode);
    stats.dims = dims;
    stats.mode = mode;
  } else {
    const d = metaGet(db, 'dims');
    stats.dims = d === null ? null : Number(d);
    stats.mode = metaGet(db, 'embedding_mode') || mode;
  }
  metaSet(db, 'last_index_at', String(Date.now()));
  metaSet(db, 'root', root);
  stats.ms = Date.now() - t0;
  return stats;
}

// ---------------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------------

function ftsQuery(tokens, op) {
  return tokens.map((t) => `"${t}"`).join(` ${op} `);
}

async function search(db, query, opts) {
  const k = Math.max(1, Number(opts && opts.k) || 8);
  const globRe = opts && opts.glob ? globToRegExp(opts.glob) : null;
  const root = metaGet(db, 'root') || DEFAULT_ROOT;
  const mode = metaGet(db, 'embedding_mode') || 'local';
  const dims = Number(metaGet(db, 'dims') || LOCAL_DIMS);

  const tokens = tokenize(query);
  let ftsRows = [];
  if (tokens.length) {
    const orRows = db.prepare(
      'SELECT chunk_id, bm25(fts) AS r FROM fts WHERE fts MATCH ? ORDER BY r LIMIT ?'
    ).all(ftsQuery(tokens, 'OR'), FTS_TOP_LARGE);
    let andRows = orRows;
    if (tokens.length > 1) {
      const cand = db.prepare(
        'SELECT chunk_id, bm25(fts) AS r FROM fts WHERE fts MATCH ? ORDER BY r LIMIT ?'
      ).all(ftsQuery(tokens, 'AND'), FTS_TOP_LARGE);
      if (cand.length > 0) andRows = cand;
    }
    ftsRows = andRows.length >= orRows.length ? andRows : orRows;
    if (ftsRows.length > 0) ftsRows = ftsRows.slice(0, Math.max(FTS_TOP, FTS_TOP_LARGE));
  }

  // Rank normalization over the fts rows kept for scoring.
  const rankById = new Map();
  if (ftsRows.length) {
    const kept = ftsRows.slice(0, FTS_TOP_LARGE);
    let rmin = Infinity;
    let rmax = -Infinity;
    for (const r of kept) {
      if (r.r < rmin) rmin = r.r;
      if (r.r > rmax) rmax = r.r;
    }
    for (const r of kept) {
      const norm = rmax === rmin ? 1 : 1 - (r.r - rmin) / (rmax - rmin);
      rankById.set(r.chunk_id, norm);
    }
  }

  const totalChunks = db.prepare('SELECT COUNT(*) AS n FROM chunks').get().n;

  // Candidate set: fts top + full scan when the corpus is small enough.
  let candidates;
  if (totalChunks < FULL_SCAN_LIMIT) {
    candidates = db.prepare(
      'SELECT c.id, c.file_id, c.heading, c.start_line, c.end_line, c.text, f.path ' +
      'FROM chunks c JOIN files f ON f.id = c.file_id ORDER BY c.id'
    ).all();
  } else {
    candidates = [];
    const byId = new Map();
    const load = (id) => {
      if (byId.has(id)) return byId.get(id);
      const row = db.prepare(
        'SELECT c.id, c.file_id, c.heading, c.start_line, c.end_line, c.text, f.path ' +
        'FROM chunks c JOIN files f ON f.id = c.file_id WHERE c.id = ?'
      ).get(id);
      if (row) byId.set(id, row);
      return row;
    };
    for (const id of rankById.keys()) {
      const row = load(id);
      if (row) candidates.push(row);
    }
  }

  // Query vector: remote endpoint when the index was built in remote mode.
  let qvec = null;
  if (mode === 'remote') {
    const cfg = embeddingsConfig();
    if (cfg) {
      try {
        qvec = await embedQueryRemote(String(query), cfg);
      } catch (e) {
        logErr(`remote query embedding failed (${e.message}); scoring by keyword rank only`);
      }
    } else {
      logErr('index uses remote embeddings but RAG_EMBEDDINGS_URL/MODEL are unset; keyword rank only');
    }
  } else {
    qvec = localEmbed(String(query), dims);
  }

  // Vectors for scoring.
  let vecById = null;
  if (qvec && totalChunks < FULL_SCAN_LIMIT) {
    vecById = new Map();
    for (const row of db.prepare('SELECT chunk_id, blob FROM vectors').all()) {
      const buf = row.blob;
      if (buf && buf.byteLength === qvec.length * 4) vecById.set(row.chunk_id, blobToVec(buf));
    }
  }

  const scored = [];
  for (const row of candidates) {
    const rel = path.relative(root, row.path).split(path.sep).join('/');
    if (globRe && !globRe.test(rel)) continue;
    const rank = rankById.get(row.id) || 0;
    let cos = 0;
    if (qvec) {
      let v;
      if (vecById) {
        v = vecById.get(row.id);
      } else {
        const vr = db.prepare('SELECT blob FROM vectors WHERE chunk_id = ?').get(row.id);
        if (vr && vr.blob && vr.blob.byteLength === qvec.length * 4) v = blobToVec(vr.blob);
      }
      if (v) cos = cosine(qvec, v);
    }
    const score = FUSE_KEYWORD * rank + FUSE_VECTOR * cos;
    scored.push({
      id: row.id,
      path: rel,
      heading: row.heading || '',
      start_line: row.start_line,
      end_line: row.end_line,
      score,
      snippet: snippetOf(row.text),
      _text: row.text,
    });
  }

  scored.sort((a, b) => b.score - a.score || a.id - b.id);
  // N6: score floor + hard cap (env RAG_MIN_SCORE / RAG_MAX_HITS, per-call min_score)
  const minScore = Math.max(0, Number(opts && opts.min_score) || Number(process.env.RAG_MIN_SCORE) || 0);
  const hardCap = Math.min(Math.max(1, Number(process.env.RAG_MAX_HITS) || 50), 200);
  return scored
    .filter((h) => Number(h.score) >= minScore)
    .slice(0, Math.min(k, hardCap))
    .map(({ _text, ...hit }) => ({ ...hit, text: _text }));
}

// ---------------------------------------------------------------------------
// Status + get
// ---------------------------------------------------------------------------

function statusOf(db) {
  const files = db.prepare('SELECT COUNT(*) AS n FROM files').get().n;
  const chunks = db.prepare('SELECT COUNT(*) AS n FROM chunks').get().n;
  const lastRaw = metaGet(db, 'last_index_at');
  const root = metaGet(db, 'root') || DEFAULT_ROOT;
  const mode = metaGet(db, 'embedding_mode') || (files ? 'local' : 'unindexed');
  const dims = metaGet(db, 'dims');

  let stale = 0;
  let staleNote = '';
  const skipCounts = { skipped_name: 0 };
  let skippedExt = 0;
  if (files > 0 && fs.existsSync(root)) {
    const existing = new Map(
      db.prepare('SELECT id, path, hash FROM files').all().map((r) => [r.path, r])
    );
    const disk = walk(root, skipCounts);
    const diskPaths = new Set();
    for (const f of disk) {
      diskPaths.add(f.abs);
      const ext = path.extname(f.rel).slice(1).toLowerCase();
      if (EXT_SKIPS.has(ext)) { skippedExt++; continue; } // never indexed: not stale
      const rec = existing.get(f.abs);
      if (!rec) { stale++; continue; }
      try {
        const loaded = loadFile(f.abs, f.rel);
        if (loaded.skip || sha256(loaded.buf) !== rec.hash) stale++;
      } catch (e) {
        stale++;
      }
    }
    for (const p of existing.keys()) {
      if (!diskPaths.has(p)) stale++;
    }
  } else if (files > 0) {
    staleNote = `root missing on disk: ${root}`;
  }

  return {
    db: expandTilde(process.env.RAG_DB || DEFAULT_DB),
    root,
    files,
    chunks,
    last_index_at: lastRaw ? nowIso(Number(lastRaw)) : null,
    stale_files: stale,
    stale_note: staleNote,
    skipped_ext: skippedExt,
    skipped_name: skipCounts.skipped_name,
    embedding_mode: mode,
    dims: dims === null ? null : Number(dims),
  };
}

function getChunk(db, id) {
  const row = db.prepare(
    'SELECT c.id, c.file_id, c.ordinal, c.heading, c.start_line, c.end_line, c.text, f.path ' +
    'FROM chunks c JOIN files f ON f.id = c.file_id WHERE c.id = ?'
  ).get(Number(id));
  if (!row) return null;
  const root = metaGet(db, 'root') || DEFAULT_ROOT;
  return {
    id: row.id,
    path: path.relative(root, row.path).split(path.sep).join('/'),
    ordinal: row.ordinal,
    heading: row.heading || '',
    start_line: row.start_line,
    end_line: row.end_line,
    text: row.text,
  };
}

// ---------------------------------------------------------------------------
// CLI
// ---------------------------------------------------------------------------

function printIndexStats(s) {
  console.log(
    `index complete: files=${s.files} rechunked=${s.rechunked} purged=${s.purged} ` +
    `chunks=${s.chunks} skipped_binary=${s.skipped_binary} skipped_ext=${s.skipped_ext} ` +
    `skipped_name=${s.skipped_name} dims=${s.dims === null ? 'n/a' : s.dims} ` +
    `mode=${s.mode} elapsed=${s.ms}ms`
  );
  console.log(`root: ${s.root}`);
}

function printHits(hits) {
  if (!hits.length) {
    console.log('no hits');
    return;
  }
  hits.forEach((h, i) => {
    const head = h.heading ? ` ${h.heading}` : '';
    console.log(
      `${i + 1}. ${h.path}:${h.start_line}-${h.end_line} (${h.score.toFixed(4)})${head}`
    );
    console.log(`   ${h.snippet}`);
  });
}

function printStatus(s) {
  console.log(`db: ${s.db}`);
  console.log(`root: ${s.root}`);
  console.log(`files: ${s.files}`);
  console.log(`chunks: ${s.chunks}`);
  console.log(`last_index_at: ${s.last_index_at || 'never'}`);
  console.log(`stale_files: ${s.stale_files}${s.stale_note ? ` (${s.stale_note})` : ''}`);
  console.log(`skipped_ext: ${s.skipped_ext}`);
  console.log(`skipped_name: ${s.skipped_name}`);
  console.log(`embedding_mode: ${s.embedding_mode}`);
  console.log(`dims: ${s.dims === null ? 'n/a' : s.dims}`);
}

async function runCli(argv) {
  const cmd = argv[0];
  const db = openDb(process.env.RAG_DB || DEFAULT_DB);
  try {
    if (cmd === 'index') {
      const root = argv[1] || metaGet(db, 'root') || DEFAULT_ROOT;
      printIndexStats(await indexRoot(db, root));
    } else if (cmd === 'search') {
      const query = argv[1];
      if (!query) throw new Error('usage: search <query> [--k N] [--glob PATTERN]');
      let k = 8;
      let glob = null;
      for (let i = 2; i < argv.length; i++) {
        if (argv[i] === '--k') { k = Number(argv[++i]); }
        else if (argv[i] === '--glob') { glob = argv[++i]; }
        else throw new Error(`unknown search option: ${argv[i]}`);
      }
      const hits = await search(db, query, { k, glob });
      printHits(hits.map((h) => ({ ...h, snippet: h.snippet })));
    } else if (cmd === 'status') {
      printStatus(statusOf(db));
    } else if (cmd === 'get') {
      const id = Number(argv[1]);
      if (!Number.isFinite(id)) throw new Error('usage: get <chunkId>');
      const c = getChunk(db, id);
      if (!c) throw new Error(`no chunk with id ${id}`);
      console.log(
        `chunk ${c.id}: ${c.path}:${c.start_line}-${c.end_line}` +
        `${c.heading ? ` heading: ${c.heading}` : ''}`
      );
      console.log(c.text);
    } else {
      throw new Error(
        'usage: node server.js index [root] | search <query> [--k N] [--glob PATTERN] | status | get <chunkId> | (no args for MCP stdio)'
      );
    }
  } finally {
    db.close();
  }
}

// ---------------------------------------------------------------------------
// MCP stdio mode
// ---------------------------------------------------------------------------

function toolDefs() {
  return [
    {
      name: 'rag_search',
      description:
        'Search the indexed workspace with keyword (FTS5) and vector ranking fused. ' +
        'Returns ranked hits with path, line range, heading, score and a snippet.',
      inputSchema: {
        type: 'object',
        properties: {
          query: { type: 'string', description: 'Search text (natural language or keywords)' },
          k: { type: 'number', description: 'Maximum hits to return (default 8)' },
          min_score: { type: 'number', description: 'Minimum hit score to return (default 0, env RAG_MIN_SCORE)' },
          glob: { type: 'string', description: 'Glob filter on the relative path, e.g. "docs/**/*.md" or "api/*"' },
        },
        required: ['query'],
      },
    },
    {
      name: 'rag_index',
      description:
        'Incremental reindex of the workspace root: hash-checks every file, re-chunks ' +
        'changed files, purges deleted ones. Safe to call repeatedly.',
      inputSchema: {
        type: 'object',
        properties: {
          root: { type: 'string', description: 'Directory to index (default: the previously indexed root or /home/node/workspace)' },
        },
      },
    },
    {
      name: 'rag_status',
      description: 'Index status: database path, root, file and chunk counts, last index time, stale file count, embedding mode and dims.',
      inputSchema: { type: 'object', properties: {} },
    },
    {
      name: 'rag_get',
      description: 'Fetch one indexed chunk by id: full text plus path, heading and line range.',
      inputSchema: {
        type: 'object',
        properties: {
          id: { type: 'number', description: 'Chunk id (from rag_search hits)' },
        },
        required: ['id'],
      },
    },
  ];
}

function textResult(text, structured) {
  const out = { content: [{ type: 'text', text }] };
  if (structured !== undefined) out.structuredContent = structured;
  return out;
}

async function callTool(params) {
  const name = params.name;
  const args = params.arguments || {};
  const db = openDb(process.env.RAG_DB || DEFAULT_DB);
  try {
    if (name === 'rag_search') {
      const query = args.query;
      if (typeof query !== 'string' || !query.trim()) {
        return textResult('error: query must be a non-empty string', { hits: [] });
      }
      const hits = await search(db, query, { k: args.k, glob: args.glob });
      const lines = hits.length
        ? hits.map((h, i) => {
            const head = h.heading ? ` ${h.heading}` : '';
            return `${i + 1}. ${h.path}:${h.start_line}-${h.end_line} (${h.score.toFixed(4)})${head}\n   ${h.snippet}`;
          })
        : ['no hits'];
      const payload = hits.map(({ text, ...rest }) => rest);
      return textResult(lines.join('\n'), { hits: payload });
    }
    if (name === 'rag_index') {
      const stats = await indexRoot(db, args.root || metaGet(db, 'root') || DEFAULT_ROOT);
      return textResult(
        `index complete: files=${stats.files} rechunked=${stats.rechunked} purged=${stats.purged} ` +
        `chunks=${stats.chunks} skipped_binary=${stats.skipped_binary} skipped_ext=${stats.skipped_ext} ` +
        `skipped_name=${stats.skipped_name} dims=${stats.dims === null ? 'n/a' : stats.dims} ` +
        `mode=${stats.mode} elapsed=${stats.ms}ms`,
        stats
      );
    }
    if (name === 'rag_status') {
      const st = statusOf(db);
      return textResult(JSON.stringify(st, null, 2), st);
    }
    if (name === 'rag_get') {
      const c = getChunk(db, args.id);
      if (!c) return textResult(`error: no chunk with id ${args.id}`, { chunk: null });
      const head = `chunk ${c.id}: ${c.path}:${c.start_line}-${c.end_line}${c.heading ? ` heading: ${c.heading}` : ''}`;
      return textResult(`${head}\n\n${c.text}`, { chunk: c });
    }
    return { content: [{ type: 'text', text: `error: unknown tool: ${name}` }], isError: true };
  } catch (e) {
    return { content: [{ type: 'text', text: `error: ${e.message}` }], isError: true };
  } finally {
    db.close();
  }
}

function writeMsg(msg) {
  process.stdout.write(JSON.stringify(msg) + '\n');
}

async function handleMcpLine(line) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (e) {
    writeMsg({ jsonrpc: '2.0', id: null, error: { code: -32700, message: 'parse error' } });
    return;
  }
  const { id, method, params } = msg || {};
  if (!method) return; // a response or garbage without a method: ignore
  try {
    if (method === 'initialize') {
      writeMsg({
        jsonrpc: '2.0',
        id,
        result: {
          protocolVersion: (params && params.protocolVersion) || '2025-06-18',
          capabilities: { tools: {} },
          serverInfo: { name: SERVER_NAME, version: SERVER_VERSION },
        },
      });
    } else if (method === 'ping') {
      writeMsg({ jsonrpc: '2.0', id, result: {} });
    } else if (method === 'tools/list') {
      writeMsg({ jsonrpc: '2.0', id, result: { tools: toolDefs() } });
    } else if (method === 'tools/call') {
      const result = await callTool(params || {});
      writeMsg({ jsonrpc: '2.0', id, result });
    } else if (method.startsWith('notifications/')) {
      // notifications (initialized, cancelled, progress): no response
    } else if (id === undefined || id === null) {
      // unknown notification: stay silent
    } else {
      writeMsg({
        jsonrpc: '2.0',
        id,
        error: { code: -32601, message: `method not found: ${method}` },
      });
    }
  } catch (e) {
    writeMsg({
      jsonrpc: '2.0',
      id,
      error: { code: -32603, message: String((e && e.message) || e) },
    });
  }
}

function startMcp() {
  let pending = '';
  let chain = Promise.resolve(); // serialize line handling: responses keep request order
  process.stdin.setEncoding('utf8');
  process.stdin.on('data', (chunk) => {
    pending += chunk;
    let idx;
    while ((idx = pending.indexOf('\n')) >= 0) {
      const line = pending.slice(0, idx).trim();
      pending = pending.slice(idx + 1);
      if (line) chain = chain.then(() => handleMcpLine(line)).catch((e) => logErr(e.message));
    }
  });
  process.stdin.on('end', () => process.exit(0));
  process.stdin.resume();
}

// ---------------------------------------------------------------------------
// Entry
// ---------------------------------------------------------------------------

async function main() {
  const argv = process.argv.slice(2);
  if (argv.length === 0) {
    startMcp();
    return;
  }
  await runCli(argv);
}

main().catch((e) => {
  logErr(e && e.stack ? e.stack : String(e));
  process.exit(1);
});
