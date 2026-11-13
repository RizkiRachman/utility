# CocoIndex Code (`cocoindex-code`)

AST-aware semantic code index for the OpenCode container. Baked at image build
time as an MCP server; this folder is documentation only — the `ccc` binary is
the MCP server, so nothing here is `COPY`'d into the image.

## What and why

`ccc` chunks source files along AST boundaries, embeds them locally, and exposes
semantic search over them. It answers "where is the code that does X" questions
that a token search misses and that a workspace-wide grep answers badly.

It complements the two search layers already in the stack rather than replacing
either:

| Layer | Owns |
|---|---|
| `lean-ctx` (`ctx_search` symbol, `ctx_impact`, `ctx_callgraph`) | exact symbols, callers, blast radius |
| `rag` (`rag_search`) | indexed workspace code + docs discovery |
| `cocoindex-code` (`ccc`) | AST-aware semantic code search, cross-repo |

Use `ccc` for meaning-level code retrieval. For impact analysis, callgraph, and
symbol lookup, use lean-ctx. For documentation, use rag.

## What got baked

- `pipx install "cocoindex-code[full]"` — pinned via
  `ARG COCOINDEX_CODE_VERSION` in `../../Dockerfile`.
- The `[full]` extra bundles **local sentence-transformers embeddings**
  (`torch` + `transformers`). No embedding API key is needed and search works
  offline once the model is cached locally.
- **Image size note:** this extra is heavy (torch pulls a large dependency
  tree). The size cost is accepted deliberately: it buys keyless, offline
  embedding, which matches the offline-first house style of every other baked
  MCP server. It is documented, not engineered around.
- Python 3.11.2 (bookworm) satisfies the upstream 3.11–3.13 requirement.
- Wheel-first: if `/pi/pip/cocoindex_code-*.whl` exists in the preinstall
  store it is installed from there with `PIP_FIND_LINKS`/`PIP_NO_INDEX`; the
  network path (`pipx install "cocoindex-code[full]==${VERSION}"`) is the
  fallback, same as the other pipx/npm blocks.

## MCP wiring

Registered in `config/opencode.json` under `mcp.servers`:

```json
"cocoindex-code": {
  "type": "local",
  "command": ["ccc", "mcp"],
  "enabled": true
}
```

Upstream constraint: the client must start `ccc mcp` **with the project as the
working directory**. The image's `WORKDIR` is `/home/node/workspace`, so the
default is already correct. Only if a different project root is needed does the
working directory have to be adjusted — do not run `ccc mcp` from `/`.

## Runtime configuration

| Setting | Where | Purpose |
|---|---|---|
| `embedding.model` | `~/.cocoindex_code/global_settings.yml` | Selects the sentence-transformers model used for embeddings |
| `COCOINDEX_CODE_EMBEDDING_MODEL` | env var | Env override for the same embedding model selection |
| `COCOINDEX_LMDB_MAP_SIZE` | env var (bytes) | Raises the LMDB map size; the fix when indexing errors with a map-full failure on large repos |
| index directory | `.cocoindex_code/` (project-local by default) | Stores the index and embeddings; redirectable to another location via the documented index directory redirect option |

The index is project-local by default so each workspace keeps its own index. A
shared location (for example a persistent volume) can be configured through the
index directory redirect option when several checkouts should share one cache.

## First-run notes

- **The first `ccc index` embeds everything** — expect it to be slow, and
  expect a **one-time model download from HuggingFace**. That download is the
  only network dependency after the image build. Build a warm index once and
  keep it (or the redirect target) on a persistent volume.
- Subsequent index runs are incremental: only changed files are re-embedded.
- After changing chunker settings, run `ccc daemon restart` so the running
  daemon picks up the new chunking behavior.
- After switching the embedding model, run `ccc reset && ccc index`. Mixing
  embeddings from two models in one index yields meaningless similarity scores.

## Verification smoke test

```bash
ccc index /home/node/workspace
ccc search "where is the MCP server registered"
```

A successful run prints ranked matches with file paths and line ranges. If the
first invocation reports a missing model, that is the one-time HuggingFace
download described above — rerun once it completes.

## Future work

1. **Offline wheel seeding — done.** `agents/opencode/populate-preinstall.sh`
   seeds the `cocoindex-code[full]` closure (the wheel plus the
   torch/transformers/sentence-transformers tree) into `pre-install/pip/`
   under its own skip-if-exists guard, the same way `mcp-server-fetch` is
   seeded. The version comes from `COCOINDEX_CODE_VERSION` in that script,
   which is env-overridable and **must match** the Dockerfile's
   `ARG COCOINDEX_CODE_VERSION` default. Purpose-built air-gapped builds now
   install local embeddings with no network hop.
2. **Consolidate support code under `supports/`.** The `rag` server currently
   lives at `agents/opencode/rag/`; it will move under `supports/` in a later
   change. That move is intentionally out of scope here.