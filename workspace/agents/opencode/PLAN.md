# opencode — Migration Plan

**Status:** PLANNING (no git repo — intentionally, per decision 2026-11-01)
**Source baseline:** `/home/node/workspace/opencode` (branch `docs/unify-skill-agent-doc-drift`, PR #1, HEAD `63be455` + local revert commit)
**Goal:** Same product as v1 — self-hosted opencode in Docker bundling workflow-state-engine, lean-ctx, graphify, MCPs, skills — but running **OpenCode v2** (`anomalyco/opencode`) instead of v1 (`sst/opencode`, npm `opencode-ai`).

---

## 1. v2 Landscape (facts gathered 2026-11-01)

| Fact | Detail | Source |
|---|---|---|
| New org | `anomalyco/opencode` (maintainer `thdxr`, original author) | npm publisher metadata |
| v2 CLI package | `@opencode/cli@2.2.5` — npm description says "bootstrap — not a functional release"; README install instructions nonetheless point at it | npm search + repo README |
| Package family | `@opencode/core` ("core runtime services"), `@opencode/plugin` ("authoring interfaces and runtime loader support for V2 plugins"), `@opencode/schema`, `@opencode/protocol`, `@opencode/util` — all 2.2.5, all published 2026-10-30 | npm search |
| Install paths | `npm i -g @opencode/cli@latest`; `brew install anomalyco/tap/opencode`; `curl -fsSL https://opencode.ai/v2/install \| bash`; desktop app (beta) | repo README (dev branch) |
| Docs | `https://opencode.ai/v2/docs` (+ `/v2/docs/agents` referenced in README) | repo README |
| Same UX concepts | `build` / `plan` built-in agents (Tab switch), `@general` subagent, TUI, `opencode` binary name | repo README |
| New v2 capability signals | third-party `ai-sdk-provider-opencode-sdk@5.0.1` targets "OpenCode 2.x via @opencode/client: sessions, streaming, **tool approvals, interactive forms**" | npm search |
| v1 remains stable channel | `opencode-ai@1.19.5` (sst), actively published (1.18.13→1.19.5 within days) | npm view |

**Verdict:** v2 is real and installable but **beta/early** — several packages self-declare "not a functional release". Migration is NOT advisable until `@opencode/cli` ships a functional release and config/agent/plugin docs stabilize.

## 2. What carries over from v1 unchanged (decisions already locked in PR #1)

- `engine/` — workflow-state-engine (16 agents incl. `orchestrator` + `design-orchestrator`, 65 skills, awesome-pr, rules.json, contract) — engine is opencode-version-agnostic (markdown + scripts)
- Session-local-only policy: `session/*` + `.session/` gitignored, `session/state.example.md` tracked example
- `pre-install/` offline store skeleton + `populate-preinstall.sh` + compose `populate` service (throwaway node:22 container) — approach A
- Dockerfile patterns: BuildKit cache mounts, store-first installs with per-package network fallback, USER root bracket around engine transform
- `.dockerignore`, model IDs (`deepseek-flash`/`glm-5.3-flash`), `.github/PULL_REQUEST_TEMPLATE.md`
- GITHUB_TOKEN passthrough in live compose (never printed/committed)

## 3. Migration deltas v1 → v2 (what must be verified/changed)

| Area | v1 (current) | v2 (to verify) | Risk |
|---|---|---|---|
| CLI package | `opencode-ai@1.19.0` (pin) | `@opencode/cli@2.x` (pin latest functional) | MEDIUM — version churn during beta |
| Install in Dockerfile | `npm install -g opencode-ai@…` | `npm install -g @opencode/cli@…` (scope changes tarball name in store: `@opencode+cli-*.tgz`) | LOW |
| Config file | `opencode.json` (554L: agents, mcp, permission, provider, compaction, plugins) | schema unknown — `@opencode/schema` package exists; may be breaking (agent frontmatter, mcp block, permissions) | **HIGH — biggest unknown** |
| Agents | 16 markdown agents + built-ins build/plan | same concepts exist in v2 README; frontmatter format to verify | MEDIUM |
| MCP servers | `mcp` block: lean-ctx (stdio), memory, fetch, everything | format may move / names change; verify local stdio servers still supported | MEDIUM |
| Plugins | `@opencode-ai/plugin@1.19.0` API; 3 plugins (model-fallback, dcp, websearch-cited) | `@opencode/plugin@2.x` new API — all 3 plugins need port or replacement | **HIGH** |
| Web/server mode | `opencode web --hostname 0.0.0.0 --port 4096` (entrypoint.sh) | command/flags unknown in v2 (client/server split? port?) | **HIGH** |
| Auth | `auth.json` in data volume, mounted/renamed by entrypoint | auth storage format to verify | MEDIUM |
| Runtime deps | node:22-bookworm-slim | confirm v2 runtime requirements (bun? node version?) | LOW |
| Engine doc URLs | agent.md/README reference opencode docs (v1 URLs) | update to `/v2/docs` paths where referenced | LOW |

## 4. Phased plan

- **P0 — Plan (this doc)** ✅
- **P1 — Scaffold copy:** copy `opencode/` → `opencode/` (exclude `.git`, `session/`, `.session/`, `pre-install/*` contents, `node_modules`, `.idea`). No `git init`. Independent compose project name (`opencode`) + same port? → use 4098 to allow parallel run.
- **P2 — Readiness gate (repeat before each attempt):** `npm view @opencode/cli` functional release? docs `/v2/docs/config` reachable? `@opencode/plugin` API stable? If any NO → stay on v1, revisit later (v1 is maintained; no urgency).
- **P3 — Upgrade:** Dockerfile package/ARG swaps; config migration (map every v1 key; keep model IDs + permissions); entrypoint web flags; plugins port; populate-preinstall.sh package list; engine doc URL touch-ups.
- **P4 — Build + smoke:** `populate` → `up -d --build`; verify: web UI on :4096, agents load (16 + build/plan), MCPs healthy, pre-install offline path used, auth works, engine instructions load (instructions[0] = /opt/engine/agent.md).
- **P5 — Stabilize:** run both stacks in parallel (v1 :4096, v2 :4098) until v2 proves stable; then optionally promote.

## 5. Risk register

1. **Beta churn** — v2 packages published days ago; APIs may break weekly. Mitigation: pin exact versions; readiness gate P2 each time.
2. **Config schema** — largest unknown; budget a full config rewrite, not a diff.
3. **Plugin API** — 3 plugins may need rewrites or temporary removal (model-fallback is resilience, dcp/websearch-cited are enhancements — degrade gracefully).
4. **Engine coupling** — engine instructions assume v1 behaviors (bash deny + ctx_shell allowlist, MCP tool names). Verify tool names unchanged in v2 before trusting engine prompts.
5. **Docs unreachable from container** — opencode.ai fetch failed during analysis; migration work needs docs via host browser or allowlisted fetch.

## 6. Open questions (user)

1. Parallel run OK (v2 on port 4098) or replace v1 outright when ready?
2. When PR #1 merges, rebase opencode scaffold copy from `main` instead of PR branch?
3. Should v2 keep `everything` demo MCP, or drop it (v1 keeps it enabled)?

---

## Addendum (2026-11-02)

First-party `@firecrawl/opencode` v1.4.0 is now adopted as an offline-vendored plugin (`engine/plugins/opencode-firecrawl`); it supersedes the removed `opencode-websearch-cited` capability first-party. Keyless `firecrawl_developer_search` works out of the box; `firecrawl_alexandria` is keyed and ask-gated by config permission. Historical sections above are preserved as written.
