# agents/openui - self-hosted OpenUI generative UI

Containerized generative-UI service built from the official
[thesysdev/openui](https://github.com/thesysdev/openui) scaffold
(`@openuidev/cli create`: Next.js + LangGraph + `@openuidev/server`), patched to
call **sumopod GLM** directly instead of the hosted Thesys gateway, and wired to
the opencode client through a stdio MCP bridge.

    opencode --MCP(stdio)--> mcp-bridge.mjs --HTTP--> openui:3000/api/chat --> sumopod GLM

## Layout

| Path | Purpose |
|------|---------|
| `app/` | Scaffolded app (CLI v0.6.3, Next.js 16 + LangGraph) |
| `app/src/agent.ts` | Model provider: `SUMOPOD_API_KEY` / `SUMOPOD_BASE_URL` via ChatOpenAI; key read lazily so image builds need no secrets; Thesys cloud-history middleware removed (in-memory history) |
| `app/src/lib/models.tsx` | Model catalog: `glm-5.3-flash` (single entry, also the default) |
| `app/src/app/layout.tsx` | System font stack (no Google Fonts fetch at build; hermetic image builds) |
| `app/Dockerfile` | Multi-stage, Next standalone output, non-root user, healthcheck |
| `app/certs/` | Corporate CA drop-in (PEM `.crt`, gitignored) - baked into image trust store |
| `mcp-bridge.mjs` | stdio MCP server, zero deps: tools `generate_ui` and `preview_url` |
| `compose-service.yml` | Fragment to paste into the root host compose (replaces the old wandb `openui` block) |
| `docker-compose.example.yaml` | Standalone example: build and run only this service |
| `.env.example` | Template for compose env |

## Quick start (standalone)

    cp .env.example .env          # fill SUMOPOD_API_KEY
    docker compose -f docker-compose.example.yaml up -d --build

Browser chat UI: http://localhost:8102

## Wire into the root stack

Paste `compose-service.yml` into the root compose (it replaces the obsolete wandb
`openui` block), then from the repo root:

    docker compose build openui && docker compose up -d openui

The service joins the `utility_default` network, so the opencode container resolves
it as `http://openui:3000` (the MCP bridge default via `OPENUI_URL`).

## opencode MCP registration

Already wired in `agents/opencode/config/opencode.json`:

    mcp.servers.openui = {
      type: "local",
      command: ["node", "/home/node/workspace/agents/openui/mcp-bridge.mjs"],
      environment: { "OPENUI_URL": "http://openui:3000" }
    }

Tools exposed to the agent:

- `generate_ui(prompt, model?)` - returns generated OpenUI Lang text
- `preview_url()` - browser URL of the chat UI

MCP servers attach when opencode restarts or a new session starts.

## API contract (what the bridge speaks)

    POST /api/chat
    { "messages": [{ "role": "user", "content": "..." }],
      "threadId": "any-string", "model": "glm-5.3-flash" }

Response: SSE stream of `event: messages` frames, each `data:` a `[chunk, metadata]`
tuple. The OpenUI Lang text accumulates in `chunk.content`; GLM reasoning arrives
separately in `additional_kwargs.reasoning_content` and is ignored by the bridge.

## Environment variables

| Var | Used by | Required | Default |
|-----|---------|----------|---------|
| `SUMOPOD_API_KEY` | app | yes (runtime) | - |
| `SUMOPOD_BASE_URL` | app | no | `https://ai.sumopod.com/v1` |
| `OPENUI_URL` | bridge | no | `http://openui:3000` |
| `OPENUI_MODEL` | bridge | no | `glm-5.3-flash` |
| `OPENUI_PUBLIC_URL` | bridge | no | `http://localhost:8102` |

## Corporate TLS certificates

On TLS-intercepting networks (symptom: `certificate verify failed` from inside
the container) the image trusts the corporate CA out of the box - same
convention as `agents/opencode/certs`:

1. Drop the CA as PEM with a `.crt` extension into `app/certs/` (gitignored,
   never committed)
2. Rebuild - the Dockerfile concatenates `certs/*.crt` into a bundle and Node
   trusts it via `NODE_EXTRA_CA_CERTS` (node:22-alpine ships no CA store
   tooling, so there is no update-ca-certificates step)

Runtime-mount alternative (CA rotates often, no rebuild wanted):

    volumes:
      - /certs/ca.crt:/zca.crt:ro
    environment:
      NODE_EXTRA_CA_CERTS: /zca.crt

With no cert in `certs/` the image still builds and runs fine on networks that
do not intercept TLS.


## Local development (no Docker)

    cd app
    npm ci && npm run generate && npm run build
    SUMOPOD_API_KEY=... npm start        # or PORT=3100 npm start

Note: `/home/node/workspace` is a Windows bind mount; `npm ci` there is extremely
slow. Copy the app to container-local storage first:
`tar cf - --exclude=node_modules . | (cd /home/node/openui-run && tar xf -)`

## Status

- [x] Scaffold patched: sumopod provider, glm-5.3-flash catalog, hermetic build
- [x] MCP bridge: handshake, tools/list, generate_ui verified
- [x] E2E local: bridge -> app -> GLM 5.3 -> OpenUI Lang document returned
- [x] Image `openui-genui:local` (460 MB) built; standalone server boots; root 200
- [x] E2E through the image: bridge -> container -> GLM -> OpenUI Lang (with CA mount)
- [ ] Host: swap the wandb `openui` block for `compose-service.yml`, then `docker compose build openui && up -d openui`
- [ ] Commit + push
