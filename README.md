# The Agent Foundry

Personal agent workspace: containerized AI coding agents that plan, build, and ship under a scored, gated workflow.

[![validate](https://github.com/RizkiRachman/utility/actions/workflows/validate.yml/badge.svg)](https://github.com/RizkiRachman/utility/actions/workflows/validate.yml)
![OpenCode](https://img.shields.io/badge/OpenCode-2.2.5-111111)
![Docker Compose](https://img.shields.io/badge/docker%20compose-5%20services-2496ED?logo=docker&logoColor=white)

## What this is

A Docker Compose stack where AI coding agents do real work. The product is [workspace/agents/opencode/](workspace/agents/opencode/README.md): an OpenCode 2.2.5 container that ships the Workflow State Engine (17 agents, 45 skills, contract-driven scoring), lean-ctx code intelligence, and six MCP servers, all version-pinned and pre-populated for offline builds. A sidecar container, [workspace/agents/openui/](workspace/agents/openui/README.md), serves generative UI over the same GLM model and is reachable from the agents through an MCP bridge. Scratch work lives in [workspace/sandbox/](workspace/sandbox/README.md), one folder per session.

## What we do

- Run every task through a gated state machine: INIT to COMPLETE via scored transitions, with a persistent session envelope as the single source of truth
- Bake the whole stack into the image: rules, skills, MCP servers, and plugins ready on first boot, no network needed after the first pull
- Publish a plain-text digest of the agent stack to Cloudflare Pages on every push, so AI agents can read the repo without cloning
- Keep runs reproducible: store-pinned package versions recorded in an audit manifest, an offline package store that travels with the workspace, skeleton-tracked runtime directories

## Project Structure

```text
utility/
├── docker-compose.example.yaml       # 5 services: opencode, openui, opencode-preinstall, opencode-scheduler, opencode-maintenance
├── wrangler.toml                     # Empty placeholder; Pages deploy is CI-only (deploy-digest.yml)
├── .github/
│   ├── workflows/validate.yml        # CI: JSON validity, bash -n sweep, cross-reference integrity, doc style (humanizer), contract score, conventions (non-blocking)
│   ├── workflows/deploy-digest.yml   # CI: packs the agent stack with repomix, deploys to Cloudflare Pages (project utility-digest)
│   └── PULL_REQUEST_TEMPLATE.md      # PR description checklist
└── workspace/
    ├── agents/
    │   ├── opencode/                 # The product (see its README)
    │   │   ├── Dockerfile            # OpenCode 2.2.5 on node:22-bookworm-slim
    │   │   ├── entrypoint.sh         # Boot chain: auth, MCP preflight, optional engine self-check, serve (serve/web probe fallback)
    │   │   ├── config/               # opencode.json: 6 MCP servers, firecrawl plugin, 20 agents; lean-ctx config template; model fallback config; rag-usage.md
    │   │   ├── rag/                  # RAG MCP server (SQLite FTS5 + vectors)
    │   │   ├── engine/               # Workflow State Engine, copied to /opt/engine at build (see its README)
    │   │   ├── docs/                 # Workflow diagrams (build-to-runtime, orchestration state machine), git mirror notes
    │   │   ├── detect-zscaler.sh     # Probes the live wire for TLS interception, refreshes auto-detected certs
    │   │   ├── populate-preinstall.sh # Fills the offline store, resolves latest versions, writes versions.lock
    │   │   ├── pre-install/          # Offline package store, 6 sections (skeleton tracked, contents gitignored)
    │   │   ├── session/              # Live orchestration state (skeleton tracked, contents gitignored)
    │   │   ├── certs/                # TLS certificates: auto-detected plus manual (contents gitignored, skeleton tracked)
    │   │   ├── docker-compose.example.yaml # Standalone single-service compose, alternative to the root file
    │   │   └── .env.template         # Copy to repository-root .env
    │   └── openui/                   # Generative-UI service (see its README)
    │       ├── app/                  # Next.js 16 + LangGraph scaffold, Dockerfile included
    │       ├── mcp-bridge.mjs        # stdio MCP bridge: generate_ui, preview_url
    │       ├── docker-compose.example.yaml # Standalone single-service compose
    │       └── .env.example
    ├── sandbox/                      # Session playground (see its README): skeleton tracked, session folders gitignored
    ├── certs/                        # TLS mount point (gitignored, skeleton tracked)
    ├── documentation/wiki/           # NPG Confluence wiki publisher (see its README)
    └── infrastructure/               # Scaffolding only, no services yet: database/postgres, database/mssql, grafana, k6, vault
```

## Documentation

Each folder carries its own README; start there for detail:

| Path | Covers |
|---|---|
| [workspace/agents/opencode/](workspace/agents/opencode/README.md) | The product: quick start, configuration, MCP servers, architecture, quality gates, troubleshooting |
| [workspace/agents/opencode/engine/](workspace/agents/opencode/engine/README.md) | Workflow State Engine reference: state machine, agents, scripts, scoring |
| [workspace/agents/opencode/docs/opencode-workflow.md](workspace/agents/opencode/docs/opencode-workflow.md) | Diagrams: offline store to runtime build flow, orchestration state machine |
| [workspace/agents/openui/](workspace/agents/openui/README.md) | Generative-UI sidecar and its MCP bridge |
| [workspace/sandbox/](workspace/sandbox/README.md) | Session playground rules |
| [workspace/documentation/wiki/](workspace/documentation/wiki/README.md) | Confluence wiki publisher |

## Offline Package Store

`workspace/agents/opencode/pre-install/` holds every third-party artifact the image needs, so builds run without network access. It is gitignored apart from `.gitkeep` placeholders and lives with the workspace volume, so a copied workspace carries a working store.

Six sections: `npm` (tarballs), `pip` (wheels), `bin` (release binaries such as lean-ctx), `apt` (`.deb` cache seeds), `git` (source mirrors), `dist` (direct-URL downloads).

- **Auto-latest.** `populate-preinstall.sh` resolves the current version of each package at populate time (npm registry for npm, PyPI JSON for wheels, the GitHub releases API for binaries). Re-running populate is the update-everything action. Set an env var (for example `OPENCODE_VERSION=2.2.5`) to pin a package instead. A resolver failure warns and falls back to the previous pin, so a registry hiccup never aborts a store build.
- **Audit manifest.** Each run writes `pre-install/versions.lock` recording every resolved version plus the store arch. It is the audit trail and the pin list for a reproducible re-run.
- **Frozen between runs.** The Dockerfile store tiers are glob-based and the store is the lockfile, so builds stay at whichever snapshot the store holds. Update by re-running populate, not by rebuilding.
- **Version-aware guards.** An artifact already present at the same version is skipped. A different version is fetched and the older copies of that package are pruned, which keeps the Dockerfile globs single-match. Pruning also runs on the skip path, so an older store self-heals. Dependency closures are add-only; the torch/transformers/sentence-transformers closure is huge and refreshes only when you ask: `REFRESH_ML=1 sh populate-preinstall.sh`.
- **Arch autodetect.** Populate reads `uname -m` (`x86_64` to `x64`, `aarch64` to `arm64`) and prunes tarballs for the other arch. The Dockerfile derives its arch from `TARGETARCH` (`amd64` to `x64`); `OPENCODE_ARCH` is an optional override for cross-builds.

## Certificates

`certs/` carries corporate MITM roots. `detect-zscaler.sh` probes the live wire on every populate run, so rotated roots are re-derived without manual work: it replaces only the `zscaler-autodetected-*.crt` set and never touches manual certificates you placed there. A failed probe changes nothing. The store build then installs everything in `certs/` into its trust store, and the image does the same at build time, so Node, pip, and git all trust the corporate proxy.

## Enforcement

lean-ctx, the mandatory access layer for reads, search, and shell, ships a baked shell allowlist. Manage it in [`workspace/agents/opencode/config/lean-ctx-config.toml`](workspace/agents/opencode/config/lean-ctx-config.toml), which the Dockerfile copies to `/home/node/.config/lean-ctx/config.toml` in the image.

- Baseline: `shell_allowlist_extra = ["docker", "sh", "bash", "sudo", "ss"]`, merged onto lean-ctx's built-in read-only allowlist.
- Extend per environment: add the bare command name to that list and rebuild, or run `lean-ctx allow <cmd>` inside the container, which persists the entry to the same file.
- Candidates in the template, commented: `opencode` (lets in-container agents verify the CLI and engine version) and `ccc` (the local AST index server, which adds a model download and a CPU cost on first index).
- Escape hatches: `shell_allowlist = []` drops all extras, `shell_security = "off"` disables shell security checks entirely.

## Diagrams

All diagrams in this repository follow one standard: Mermaid blocks inside markdown, one diagram per concept, no binary images. The build-to-runtime flow and the orchestration state machine live in [opencode-workflow.md](workspace/agents/opencode/docs/opencode-workflow.md); the stack architecture in the [opencode README](workspace/agents/opencode/README.md); the engine state machine in the [engine README](workspace/agents/opencode/engine/README.md).

## Contributing and License

This is a personal workspace and not open for external contribution. No LICENSE file ships with the repository; treat the contents as proprietary and internal use only.