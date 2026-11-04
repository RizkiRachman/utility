'use strict';

/*
 * java-check.js — assertion helper for rag/test.sh case 9.
 * Opens the rag SQLite database given as argv[1] and validates the Java
 * chunking invariants on UserService.java:
 *   - the file produced at least two chunks
 *   - headings carry package and class context (package com.example; > UserService)
 *   - the long method was hard split into more than one chunk
 *   - the distinctive identifier is present in some chunk text
 * Prints the first processBatch chunk id as "CHUNK_ID=<n>" so the caller
 * can exercise the rag_get path on it. Exits 0 when all assertions hold.
 */

const { DatabaseSync } = require('node:sqlite');

const dbPath = process.argv[2];
if (!dbPath) {
  console.error('usage: node java-check.js <rag.db>');
  process.exit(1);
}

const db = new DatabaseSync(dbPath);
const rows = db.prepare(
  'SELECT c.id, c.heading, c.start_line, c.end_line, c.text ' +
  'FROM chunks c JOIN files f ON f.id = c.file_id ' +
  "WHERE f.path LIKE '%UserService.java' ORDER BY c.ordinal"
).all();
db.close();

let ok = true;
const check = (label, cond) => {
  console.log(`CHECK ${label}: ${cond ? 'ok' : 'FAIL'}`);
  if (!cond) ok = false;
};

check('UserService.java has at least 2 chunks', rows.length >= 2);
check('some heading carries package com.example;',
  rows.some((r) => r.heading.includes('package com.example;')));
check('some heading carries the class name UserService',
  rows.some((r) => /(^|> )UserService( |$)/.test(r.heading)));
const batch = rows.filter((r) => r.heading.includes('processBatch'));
check('long method hard split (>=2 processBatch chunks)', batch.length >= 2);
check('full heading shape pkg > class > method',
  rows.some((r) => /^package com\.example; > UserService > \w/.test(r.heading)));
check('marmaladeDeduplication present in chunk text',
  rows.some((r) => r.text.includes('marmaladeDeduplication')));

if (batch.length) console.log(`CHUNK_ID=${batch[0].id}`);
process.exit(ok ? 0 : 1);
