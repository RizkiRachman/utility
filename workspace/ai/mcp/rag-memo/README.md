# rag-memo

Agnostic, zero-dependency MCP module for hybrid semantic search (`rag_*`) and write-gated agent memory (`memo_*`), backed by a single SQLite database.

## Design

- **Zero heavy runtime:** Uses Node.js 22 built-in `node:sqlite` (FTS5 + Float32 vector blobs). No PyTorch, `transformers`, or external vector database daemon.
- **Pluggable embeddings:** Defaults to deterministic offline hashed n-grams. Set `RAG_EMBEDDINGS_URL`, `RAG_EMBEDDINGS_MODEL`, and `RAG_EMBEDDINGS_KEY` to switch to any OpenAI-compatible `/v1/embeddings` endpoint.
- **Host-agnostic:** Works with OpenCode, Claude Code, Cursor, or any MCP client over `stdio` JSON-RPC.
- **Coexistence toggle:** Set `MEMO_ENABLED=false` if your host runtime already uses another memory MCP or plugin (such as `lean-ctx` or Mem0).

## Quick Start

1. Build the local MCP image:
   ```bash
   docker build -t rag-memo-mcp:local .
   ```
2. Merge `config-entry.json` into your client's `mcp.servers` configuration (for example, `workspace/agents/opencode/config/opencode.json`), or run standalone with `docker-compose.example.yaml`.

## Configuration

| Variable | Default | Description |
|---|---|---|
| `RAG_DB` | `/data/rag-memo.db` | SQLite database path |
| `MEMO_ENABLED` | `true` | Expose `memo_*` tools alongside `rag_*` |
| `RAG_EMBEDDINGS_URL` | (empty) | Optional OpenAI-compatible `/v1/embeddings` URL |
| `RAG_EMBEDDINGS_MODEL` | (empty) | Embedding model ID for the remote endpoint |
| `RAG_EMBEDDINGS_KEY` | (empty) | Bearer token for the remote endpoint |

## Tools

- **RAG:** `rag_search`, `rag_index`, `rag_get`, `rag_status`
- **Memo:** `memo_recall`, `memo_remember`, `memo_forget`, `memo_status`

See [rag-memo-plan.md](../../../documentation/rag-memo-plan.md) for the full architecture and rollout plan.
