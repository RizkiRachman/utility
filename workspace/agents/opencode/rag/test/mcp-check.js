'use strict';

/*
 * mcp-check.js — assertion helper for rag/test.sh case 6.
 * Reads the JSON-RPC response lines produced by `node server.js` (MCP stdio
 * mode) from the file given as argv[1] and validates the handshake:
 *   id 1: initialize  -> serverInfo.name === "rag"
 *   id 2: tools/list  -> exactly 4 tools: rag_search, rag_index, rag_status, rag_get
 *   id 3: tools/call rag_search -> hits include getting-started.md
 * Exits 0 when every assertion holds, 1 otherwise. Prints one CHECK line each.
 */

const fs = require('node:fs');

const file = process.argv[2];
if (!file) {
  console.error('usage: node mcp-check.js <responses.jsonl>');
  process.exit(1);
}

const lines = fs.readFileSync(file, 'utf8').split('\n').filter((l) => l.trim());
const byId = new Map();
for (const line of lines) {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch (e) {
    console.log(`CHECK non-JSON stdout line: FAIL (${e.message})`);
    process.exit(1);
  }
  if (msg && msg.id !== undefined && msg.id !== null) byId.set(msg.id, msg);
}

let ok = true;
const check = (label, cond) => {
  console.log(`CHECK ${label}: ${cond ? 'ok' : 'FAIL'}`);
  if (!cond) ok = false;
};

const init = byId.get(1);
check('initialize serverInfo.name == rag', !!(init && init.result && init.result.serverInfo
  && init.result.serverInfo.name === 'rag'));

const list = byId.get(2);
const toolNames = list && list.result && Array.isArray(list.result.tools)
  ? list.result.tools.map((t) => t.name) : [];
check('tools/list has 4 tools', toolNames.length === 4);
for (const t of ['rag_search', 'rag_index', 'rag_status', 'rag_get']) {
  check(`tools/list includes ${t}`, toolNames.includes(t));
}

const call = byId.get(3);
let hits = [];
if (call && call.result && call.result.structuredContent && Array.isArray(call.result.structuredContent.hits)) {
  hits = call.result.structuredContent.hits;
} else if (call && call.result && Array.isArray(call.result.content)) {
  const text = call.result.content.map((c) => c.text || '').join('\n');
  hits = text.includes('getting-started.md') ? [{ path: 'getting-started.md' }] : [];
}
check('tools/call rag_search hits include getting-started.md',
  hits.some((h) => String(h.path).includes('getting-started.md')));

process.exit(ok ? 0 : 1);
