<!-- omit from toc -->
<a id="readme-top"></a>
# CocoIndex Code

AST-aware semantic code search for the OpenCode container. The `ccc` binary is baked at image build time and registered as an MCP server.

<p>
  <img alt="type: MCP server" src="https://img.shields.io/badge/type-MCP%20server-4a8ad6">
  <img alt="search: AST semantic" src="https://img.shields.io/badge/search-AST%20semantic-8250DF">
  <img alt="embeddings: local offline" src="https://img.shields.io/badge/embeddings-local%20offline-1F883D">
</p>

`ccc` chunks source files along AST boundaries, embeds them locally, and serves semantic search over the result. It answers "where is the code that does X" questions that a token search misses and that a workspace-wide grep answers badly.

This folder is documentation only. The `ccc` binary is the MCP server, so nothing here is copied into the image.

## Where it fits

It complements the other search layers rather than replacing them.

| Layer | Owns |
|-------|------|
| lean-ctx (`ctx_search` symbol, `ctx_impact`, `ctx_callgraph`) | exact symbols, callers, blast radius |
| rag (`rag_search`) | indexed workspace code and docs discovery |
| context7 | external library and framework documentation |
| cocoindex-code (`ccc`) | AST-aware semantic code retrieval, across repos |

Use `ccc` for meaning-level retrieval. Use lean-ctx for impact analysis, callgraph and symbol lookup. Use rag for docs and workspace discovery.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## What got baked

- `pipx install "cocoindex-code[full]"`, pinned by `ARG COCOINDEX_CODE_VERSION` in `../../Dockerfile`.
- Local sentence-transformers embeddings (`torch`, `transformers`, `sentence-transformers`). No embedding API key, and search works offline once the model is cached.
- Python 3.11.2 from bookworm satisfies the upstream 3.11 to 3.13 requirement.
- `HOME=/home/node ccc init` at build time, so the global settings file exists before first boot.
- The block verifies with `ccc --help`, not `ccc --version`: `ccc` is a typer CLI with no `--version` flag (it exits 2), which would abort `set -eux`.

Image size note: embeddings land at roughly 200 MB, not 2 to 3 GB. The build resolves `torch` from `https://download.pytorch.org/whl/cpu` via `PIP_EXTRA_INDEX_URL`, so pip picks the CPU wheel instead of the PyPI CUDA build and its `nvidia-*` closure. The CPU wheel carries a `+cpu` local version that sorts above the plain PyPI version, so no pin is needed. The cost is accepted: it buys keyless offline embedding, matching the offline-first style of the other baked MCP servers.

Install order inside the build:

1. Wheel-first. If `/pi/pip/cocoindex_code-*.whl` exists in the preinstall store, install from there with `PIP_FIND_LINKS` and `PIP_NO_INDEX`.
2. Network fallback: `pipx install "cocoindex-code[full]==${VERSION}"`, same as the other pipx and npm blocks.
3. Extras injection, three tiers. The store wheel carries no extras, so `torch`, `transformers` and `sentence-transformers` are injected separately: store wheels (`PIP_FIND_LINKS=/pi/pip`, `PIP_NO_INDEX`), then network inject, then warn-only. The warn-only tier is air-gap safe: the layer succeeds and `ccc` still works, embeddings just need network at runtime.

The store often lacks platform-matching torch wheels, since binary wheels must match the container platform, so the network tier is what normally succeeds there. `populate-preinstall.sh` seeds the same CPU embedding closure by downloading the base wheel and then the deps from the CPU index, avoiding CUDA for the same reason.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## MCP wiring

Registered in `config/opencode.json` under `mcp.servers`:

```json
"cocoindex-code": {
  "type": "local",
  "command": ["ccc", "mcp"],
  "enabled": true
}
```

Upstream constraint: the client must start `ccc mcp` with the project as the working directory. The image `WORKDIR` is `/home/node/workspace`, so the default is already correct. Change it only when a different project root is needed, and never run `ccc mcp` from `/`.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Quick start

One-time indexing, then a search smoke test:

```bash
# first run embeds everything and downloads the model once
ccc index /home/node/workspace

# ranked matches with paths and line ranges
ccc search "where is the MCP server registered"
```

A successful search prints ranked matches with file paths and line ranges. If the first invocation reports a missing model, that is the one-time HuggingFace download; rerun it once the download completes.

Index maintenance:

```bash
ccc daemon restart   # after changing chunker settings
ccc reset && ccc index   # after switching the embedding model
```

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Configuration

| Setting | Where | Description |
|---------|-------|-------------|
| `embedding.model` | `~/.cocoindex_code/global_settings.yml` | Sentence-transformers model used for embeddings |
| `COCOINDEX_CODE_EMBEDDING_MODEL` | env var | Env override for the same model selection |
| `COCOINDEX_LMDB_MAP_SIZE` | env var, bytes | Raises the LMDB map size. The fix for a map-full failure when indexing large repos |
| index directory | `.cocoindex_code/` (project-local by default) | Stores the index and embeddings. Redirectable via the index directory option |

The index is project-local by default, so each workspace keeps its own. A shared location, such as a persistent volume, can be configured through the index directory redirect option when several checkouts should share one cache.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## First-run notes

- The first `ccc index` embeds everything, so expect it to be slow, and expect a one-time model download from HuggingFace. That download is the only network dependency after the image build. Build a warm index once and keep it, or its redirect target, on a persistent volume.
- Later index runs are incremental: only changed files are re-embedded.
- After changing chunker settings, run `ccc daemon restart` so the running daemon picks up the new chunking behavior.
- After switching the embedding model, run `ccc reset && ccc index`. Mixing embeddings from two models in one index yields meaningless similarity scores.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Troubleshooting

**`cocoindex-code` fails to initialize on connect.** opencode logs `FAIL cocoindex-code - no initialize response within 20s`, and `opencode.log` shows `ccc mcp` exited with code 1:

```
Global settings not found: /home/node/.cocoindex_code/global_settings.yml
```

Cause: the global settings file was never created, which affects pre-bake images and hand-built containers. Fix: run `ccc init` once in the container, then restart opencode. Images built from this change onward bake the file at build time, so this only affects older images.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Future work

1. Offline wheel seeding, done. `agents/opencode/populate-preinstall.sh` seeds the `cocoindex-code[full]` closure, the wheel plus the torch/transformers/sentence-transformers tree, into the workspace-root `pre-installer/pip/` under its own skip-if-exists guard, the same way `mcp-server-fetch` is seeded. The version comes from `COCOINDEX_CODE_VERSION` in that script, which is env-overridable and must match the Dockerfile default.
2. Consolidate support code under `supports/`. The rag server currently lives at `agents/opencode/rag/` and will move under `supports/` later. That move is out of scope here.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## License

Internal tooling. The upstream cocoindex-code package carries its own license.