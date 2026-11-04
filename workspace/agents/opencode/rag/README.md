<!-- omit from toc -->
# rag

Retrieval-Augmented Generation MCP server for the opencode workspace: it indexes the workspace tree into SQLite (FTS5 keyword index plus Float32 vectors) and serves fused keyword + vector search to the agent. One file, `server.js`, zero npm dependencies, node core modules only.

It runs in two modes from the same script:

| Mode | Invocation | Transport |
|---|---|---|
| MCP server | `node /opt/rag/server.js` (no args) | JSON-RPC 2.0 over stdio, newline-delimited; only JSON-RPC messages go to stdout |
| CLI | `node server.js <command>` | Human-readable stdout, for indexing and inspection from a shell |

## Tools

| Tool | Arguments | Returns |
|---|---|---|
| `rag_search` | `query` (string, required), `k` (number, default 8), `glob` (string, e.g. `docs/**/*.md`) | Ranked hits as `path:startline-endline (score) heading` plus a snippet per hit; `structuredContent` carries the same hits as JSON |
| `rag_index` | `root` (string, optional) | Incremental reindex stats: files, re-chunked, purged, chunks, skipped binary/extension/name counts, dims, mode, elapsed |
| `rag_status` | (none) | JSON status: db path, root, file and chunk counts, last index time, stale file count, embedding mode, dims |
| `rag_get` | `id` (number, required) | Full chunk text with path, heading, and line range |

Search scoring fuses an FTS5 bm25 rank (weight 0.6) with cosine similarity over the vector table (weight 0.4). Candidates are the FTS top hits plus a full scan while the corpus stays under 2000 chunks; above that, the FTS top 200. A glob pattern, if given, filters candidate paths before ranking.

## CLI usage

```bash
node server.js index [rootPath]            # incremental index, prints stats
node server.js search "quantum marmalade" --k 5 --glob "docs/**/*.md"
node server.js status                      # db path, counts, stale files, embedding mode
node server.js get 42                      # full chunk text by id
```

Indexing is incremental: every file is hash checked, unchanged files are skipped, changed files are re-chunked, and files deleted from disk are purged along with their chunks, FTS rows, and vectors.

## Embeddings

| Variable | Default | Description |
|---|---|---|
| `RAG_EMBEDDINGS_URL` | (empty) | OpenAI-compatible `/v1/embeddings` endpoint; set it together with the model to leave local mode |
| `RAG_EMBEDDINGS_MODEL` | (empty) | Embeddings model id sent in the request body |
| `RAG_EMBEDDINGS_KEY` | (empty) | Bearer key sent as the `Authorization` header |
| `RAG_DB` | `~/.local/share/opencode/rag/rag.db` | SQLite database file (parent directory is created) |

Default mode is `local`: deterministic hashed n-gram vectors (word unigrams and bigrams plus char 4-grams, fnv1a-hashed into 256 buckets, L2 normalized). It needs no network, no model, and produces identical vectors on every run. With the three `RAG_EMBEDDINGS_*` variables set, indexing batches texts (32 per request) to the endpoint and stores its vectors instead; if a request fails mid-run, the run falls back to local and says so on stderr. The search side uses whichever mode the index was built with, and in remote mode embeds the query text against the same endpoint.

## Storage

One SQLite database (WAL mode) at `RAG_DB`:

| Table | Purpose |
|---|---|
| `files` | One row per indexed file: absolute path, sha256 hash, size, mtime, indexed time |
| `chunks` | One row per chunk: file id, ordinal, heading path, start and end line, text |
| `fts` | FTS5 shadow of chunk text (`porter unicode61` tokenizer) |
| `vectors` | Float32 little-endian blob per chunk |
| `meta` | `dims`, `embedding_mode`, `last_index_at`, indexed root |

## Indexing rules

Markdown, Java, and everything else each get their own chunker. Java files (`.java`) are split on method boundaries: a brace-depth scan (line comments, string literals, and char literals are respected; block comments are not tracked) closes a chunk when depth returns to the class-body level and at least 400 characters have accumulated, and any chunk above about 1400 characters is hard split at the next line boundary. Headings carry `package > class > method` context (best effort: constructors use the class name, and files without recognizable braces fall back to plain-text chunking). Chunk text stays a raw slice of the file; the heading is metadata only, same as markdown.

| Rule | Value |
|---|---|
| Markdown chunking | Split on headings; each chunk keeps its heading path |
| Java chunking | Split on method boundaries; heading carries `package > class > method` |
| Other code and plain text | Split on blank-line boundaries, about 1200 chars per chunk with about 150 chars of overlap |
| File cap | Files above 512 KB are skipped |
| Binary detection | First bytes scanned for a null byte; extension skips run after it |
| Skipped directories | `.git`, `node_modules`, `__pycache__`, `.next`, `dist`, `pre-install`, `graphify-out`, `session`, `.session`, `.venv`, and build outputs: `target`, `build`, `.gradle`, `.mvn`, `out`, `.settings`, `.idea`, `bin`, `.classpath` |
| Skipped filenames | `package-lock.json`, `yarn.lock`, `pnpm-lock.yaml`, `gradle.lockfile`, `.DS_Store`, `Thumbs.db` |
| Skipped extensions | Archives (`jar`, `war`, `zip`, `tar`, `gz`, ...), compiled artifacts (`class`, `exe`, `dll`, `so`, `dylib`, ...), images, fonts, office and media files; `svg` stays indexed |
| Default root | `/home/node/workspace` |

## Offline guarantees

No runtime downloads: the server is a single node script in the image (`/opt/rag/server.js`) and compose bind-mounts the same directory read-only so edits activate without a rebuild. Local hashed-vector mode does no network I/O at all, and the offline pre-install store needs nothing for rag. The optional remote embeddings endpoint is the only network path, and it is used only when its three variables are set. Nothing in the opencode boot chain depends on rag: a missing or failed index leaves every other server untouched.

## Engine integration

The engine wires rag in as an advisory discovery layer. Touchpoints:

- [`../engine/agent.md`](../engine/agent.md): the Retrieval Balance section in the tool usage reference, including the guardrails against citing unverified snippets.
- [`../engine/agents/developer.md`](../engine/agents/developer.md), [`../engine/agents/explorer.md`](../engine/agents/explorer.md), [`../engine/agents/system-analyst.md`](../engine/agents/system-analyst.md): convention lookup before non-trivial edits, conceptual first-pass discovery, and a complement to impact analysis.
- [`../engine/doc/skill-conventions.md`](../engine/doc/skill-conventions.md): the paragraph that routes skill users to the index for project-specific facts.
- [`../config/rag-usage.md`](../config/rag-usage.md): agent-facing usage instructions.

Advisory only: no scoring gate, no mandatory tool call. Hits are anchors; open the cited file region before relying on them.
