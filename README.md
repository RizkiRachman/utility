# The Agent Foundry

Personal agent workspace: containerized AI coding agents that plan, build, and ship under a scored, gated workflow.

[![validate](https://github.com/RizkiRachman/utility/actions/workflows/validate.yml/badge.svg)](https://github.com/RizkiRachman/utility/actions/workflows/validate.yml)
![OpenCode](https://img.shields.io/badge/OpenCode-2.2.5-111111)
![Docker Compose](https://img.shields.io/badge/docker%20compose-5%20services-2496ED?logo=docker&logoColor=white)

## What this is

A Docker Compose stack where AI coding agents do real work. The product is [workspace/agents/opencode/](workspace/agents/opencode/README.md): an OpenCode 2.2.5 container that ships the Workflow State Engine (17 agents, 45 skills, contract-driven scoring), lean-ctx code intelligence, and five MCP servers, all version-pinned and pre-populated for offline builds. A sidecar container, [workspace/agents/openui/](workspace/agents/openui/README.md), serves generative UI over the same GLM model and is reachable from the agents through an MCP bridge. Scratch work lives in [workspace/sandbox/](workspace/sandbox/README.md), one folder per session.

## What we do

- Run every task through a gated state machine: INIT to COMPLETE via scored transitions, with a persistent session envelope as the single source of truth
- Bake the whole stack into the image: rules, skills, MCP servers, and plugins ready on first boot, no network needed after the first pull
- Publish a plain-text digest of the agent stack to Cloudflare Pages on every push, so AI agents can read the repo without cloning
- Keep runs reproducible: pinned versions, an offline package store, skeleton-tracked runtime directories

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
    │   │   ├── config/               # opencode.json: 5 MCP servers, firecrawl plugin, 20 agents; model fallback config; rag-usage.md
    │   │   ├── rag/                  # RAG MCP server (SQLite FTS5 + vectors)
    │   │   ├── engine/               # Workflow State Engine, copied to /opt/engine at build (see its README)
    │   │   ├── populate-preinstall.sh # Fills the offline store; runs inside the opencode-preinstall container
    │   │   ├── pre-install/          # Offline package store (skeleton tracked, contents gitignored)
    │   │   ├── session/              # Live orchestration state (skeleton tracked, contents gitignored)
    │   │   ├── certs/                # TLS mount point (gitignored, skeleton tracked)
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
| [workspace/agents/openui/](workspace/agents/openui/README.md) | Generative-UI sidecar and its MCP bridge |
| [workspace/sandbox/](workspace/sandbox/README.md) | Session playground rules |
| [workspace/documentation/wiki/](workspace/documentation/wiki/README.md) | Confluence wiki publisher |

## Diagrams

All diagrams in this repository follow one standard: Mermaid blocks inside markdown, one diagram per concept, no binary images. The stack architecture lives in the [opencode README](workspace/agents/opencode/README.md); the engine state machine in the [engine README](workspace/agents/opencode/engine/README.md).

## Contributing and License

This is a personal workspace and not open for external contribution. No LICENSE file ships with the repository; treat the contents as proprietary and internal use only.
