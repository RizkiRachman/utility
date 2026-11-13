<!-- omit from toc -->
<a id="readme-top"></a>
# openui

Self-hosted generative UI service for the opencode workspace. A containerized OpenUI app renders live UI from OpenUI Lang text, exposed to the opencode client through a zero-dependency stdio MCP bridge.

<p>
  <img alt="type: compose service" src="https://img.shields.io/badge/type-compose%20service-2496ED">
  <img alt="bridge: stdio MCP, zero deps" src="https://img.shields.io/badge/bridge-stdio%20MCP%2C%20zero%20deps-1F883D">
  <img alt="provider: sumopod GLM" src="https://img.shields.io/badge/provider-sumopod%20GLM-4a8ad6">
</p>

Built from the official [thesysdev/openui](https://github.com/thesysdev/openui) scaffold (`@openuidev/cli create`, Next.js plus LangGraph plus `@openuidev/server`), patched to call sumopod GLM directly instead of the hosted Thesys gateway.

```text
opencode --MCP(stdio)--> mcp-bridge.mjs --HTTP--> openui:3000/api/chat --> sumopod GLM
```

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Contents

| Path | Purpose |
|------|---------|
| `app/` | Scaffolded app, CLI v0.6.3, Next.js 16 plus LangGraph |
| `app/src/agent.ts` | Model provider: `SUMOPOD_API_KEY` and `SUMOPOD_BASE_URL` via ChatOpenAI. Key read lazily so image builds need no secrets. Thesys cloud-history middleware removed, in-memory history |
| `app/src/lib/models.tsx` | Model catalog: `glm-5.3-flash`, single entry and also the default |
| `app/src/app/layout.tsx` | System font stack, no Google Fonts fetch at build, so image builds stay hermetic |
| `app/src/components/cloud-chat.tsx` | Cloud storage removed, `AgentInterface` runs on in-memory history with no Thesys and no `/api/frontend-token` |
| `app/Dockerfile` | Multi-stage, Next standalone output, non-root user, healthcheck |
| `app/certs/` | Corporate CA drop-in (PEM `.crt`, gitignored), baked into the image trust store |
| `mcp-bridge.mjs` | stdio MCP server, zero deps. Tools `generate_ui` and `preview_url` |
| `compose-service.yml` | Fragment to paste into the root host compose, replaces the old wandb `openui` block |
| `docker-compose.example.yaml` | Standalone example: build and run only this service |
| `.env.example` | Template for compose env |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Quick start (standalone)

```bash
cp .env.example .env                     # fill SUMOPOD_API_KEY
docker compose -f docker-compose.example.yaml up -d --build
```

Browser chat UI: <http://localhost:8102>. The compose file publishes `127.0.0.1:8102` to container port `3000` and declares a healthcheck against `/`.

## Wire into the root stack

Paste `compose-service.yml` into the root compose, replacing the obsolete wandb `openui` block, then from the repo root:

```bash
docker compose build openui && docker compose up -d openui
```

The service joins the `utility_default` network, so the opencode container resolves it as `http://openui:3000`, which is the MCP bridge default via `OPENUI_URL`.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Configuration

| Variable | Used by | Required | Default | Description |
|----------|---------|----------|---------|-------------|
| `SUMOPOD_API_KEY` | app | yes, runtime | none | Provider key. Read lazily so builds need no secret |
| `SUMOPOD_BASE_URL` | app | no | `https://ai.sumopod.com/v1` | OpenAI-compatible provider base |
| `SUMOPOD_BASE_MODEL` | app | no | `glm-5.3-flash` | Model id in `.env.example` |
| `OPENUI_URL` | bridge | no | `http://openui:3000` | App base URL the bridge calls |
| `OPENUI_MODEL` | bridge | no | `glm-5.3-flash` | Model sent in the chat request |
| `OPENUI_PUBLIC_URL` | bridge | no | `http://localhost:8102` | URL `preview_url` returns |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## MCP registration

Already wired in `agents/opencode/config/opencode.json`:

```json
"openui": {
  "type": "local",
  "command": ["node", "/home/node/workspace/agents/openui/mcp-bridge.mjs"],
  "environment": { "OPENUI_URL": "http://openui:3000" }
}
```

Tools exposed to the agent:

| Tool | Arguments | Returns |
|------|-----------|---------|
| `generate_ui` | `prompt` (string), `model` (optional) | Generated OpenUI Lang text |
| `preview_url` | none | Browser URL of the chat UI |

MCP servers attach when opencode restarts or a new session starts.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## API contract

What the bridge speaks:

```http
POST /api/chat
{
  "messages": [{ "role": "user", "content": "..." }],
  "threadId": "any-string",
  "model": "glm-5.3-flash"
}
```

The response is an SSE stream of `event: messages` frames, each `data:` line a `[chunk, metadata]` tuple. OpenUI Lang text accumulates in `chunk.content`. GLM reasoning arrives separately in `additional_kwargs.reasoning_content` and the bridge ignores it.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Corporate TLS certificates

On TLS-intercepting networks the symptom is `certificate verify failed` from inside the container. The image trusts a corporate CA once it is dropped in, same convention as `agents/opencode/certs`.

1. Drop the CA as PEM with a `.crt` extension into `app/certs/`. Gitignored, never committed.
2. Rebuild. The Dockerfile concatenates `certs/*.crt` into a bundle and Node trusts it via `NODE_EXTRA_CA_CERTS`. `node:22-alpine` ships no CA store tooling, so there is no `update-ca-certificates` step.

Runtime-mount alternative, for a CA that rotates often and you do not want to rebuild:

```yaml
volumes:
  - /certs/ca.crt:/zca.crt:ro
environment:
  NODE_EXTRA_CA_CERTS: /zca.crt
```

With no cert in `certs/` the image still builds and runs fine on networks that do not intercept TLS.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Local development (no Docker)

```bash
cd app
npm ci && npm run generate && npm run build
SUMOPOD_API_KEY=... npm start            # or PORT=3100 npm start
```

`/home/node/workspace` is a Windows bind mount, so `npm ci` there is extremely slow. Copy the app to container-local storage first:

```bash
tar cf - --exclude=node_modules . | (cd /home/node/openui-run && tar xf -)
```

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Status

- [x] Scaffold patched: sumopod provider, `glm-5.3-flash` catalog, hermetic build
- [x] MCP bridge: handshake, `tools/list`, `generate_ui` verified
- [x] E2E local: bridge to app to GLM 5.3, OpenUI Lang document returned
- [x] Image `openui-genui:local` (460 MB) built, standalone server boots, root returns 200
- [x] E2E through the image: bridge to container to GLM, OpenUI Lang returned with CA mount
- [ ] Host: swap the wandb `openui` block for `compose-service.yml`, then `docker compose build openui && docker compose up -d openui`
- [ ] Commit and push

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## License

Upstream OpenUI carries its own license. This folder is internal tooling with no separate license.