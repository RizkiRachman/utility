<!-- omit from toc -->
<a id="readme-top"></a>
# Workflow State Engine

![states](https://img.shields.io/badge/states-8%2B1-0969DA?style=for-the-badge)
![agents](https://img.shields.io/badge/agents-16-8250DF?style=for-the-badge)
![skills](https://img.shields.io/badge/skills-66-1F883D?style=for-the-badge)
![scripts](https://img.shields.io/badge/scripts-37-BF8700?style=for-the-badge)

<!-- omit from toc -->
### Contract-driven state machine orchestration engine for AI agent workflows

State machine: `INIT → PLAN → PLAN_SCORED → EXECUTE → EXECUTE_SCORED → REVIEW → REVIEW_SCORED → COMPLETE`

Single source of truth for all AI agents. The canonical agent instruction file is [`agent.md`](agent.md), which is `instructions[0]` for every agent.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Table of Contents

1. [About The Project](#about-the-project)
   - [Built With](#built-with)
2. [Getting Started](#getting-started)
   - [Prerequisites](#prerequisites)
   - [Build](#build)
   - [Configure](#configure)
   - [Run](#run)
   - [Verify](#verify)
3. [Where State Lives](#where-state-lives)
4. [Usage](#usage)
5. [Architecture](#architecture)
6. [State Machine](#state-machine)
7. [Scoring Pipeline](#scoring-pipeline)
8. [Roadmap](#roadmap)
9. [FAQ](#faq)
10. [Troubleshooting](#troubleshooting)
11. [Contributing](#contributing)
12. [License](#license)
13. [Acknowledgments](#acknowledgments)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## About The Project

This is a reusable orchestration toolkit for AI coding agents. It codifies agent collaboration into a gated state machine (8 forward-flow states + BLOCKED escalation) that ensures:

- **Every output is scored** via a three-tier pipeline (rule checks → LLM-as-judge → combined verdict)
- **Every decision is tracked** in the shared JSON envelope (`session/contract.json`)
- **Every session learns** from the last: lessons and patterns persist cross-session via `lean-ctx ctx_knowledge`
- **Every delegation is gated**: agents only transition if scoring thresholds are met

### Built With

This project is a documentation and configuration toolkit for AI agents. It uses:

- [OpenCode](https://www.npmjs.com/package/@opencode/cli): AI agent platform (`@opencode/cli`, npm `anomalyco/opencode`)
- [lean-ctx](https://github.com/yvgude/lean-ctx): compressed context management + code intelligence
- [Graphify](https://pypi.org/project/graphifyy/): knowledge graph builder (`graphifyy[mcp]`, PyPI)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Getting Started

The engine ships **inside the container image**: the Dockerfile copies `engine/` to `/opt/engine/` and symlinks it into OpenCode's config directory (`~/.config/opencode/{agent.md,agents,skills,commands,rules,contract,usage,doc}` → `/opt/engine/*`).

### Prerequisites

- **Docker**: to build and run the image
- **OpenCode**: installed in the image (baked at build time)
- **lean-ctx**: compressed file reads, shell, knowledge persistence, session management; installed in the image

### Build

The Dockerfile bundles OpenCode, lean-ctx, Graphify, and Context7, then copies the engine. It installs packages from the offline store in `pre-install/` (mounted as the `preinstall` build context), so pass that context explicitly:

```sh
docker build --build-context preinstall=./pre-install -t opencode:local .
```

`engine/` changes take effect on **rebuild**.

### Configure

Configuration is **not baked into the image**; it is bind-mounted read-only from `config/`:

```sh
# config/opencode.json is V2-native; edit in place, or start from the template:
cp engine/opencode.json.template config/opencode.json
# Edit config/opencode.json — set models/providers; API keys come from compose env
```

Mount it at `~/.config/opencode/opencode.json` when running. Config changes take effect on **restart**.

### Run

```sh
docker run --rm -it \
  -e OPENCODE_API_KEY="<your-key>" \
  -v "$PWD/config/opencode.json":/home/node/.config/opencode/opencode.json:ro \
  -p 4096:4096 \
  opencode:local
```

The entrypoint configures auth (writes `OPENCODE_API_KEY` to `auth.json`, then unsets it), optionally builds the Graphify index, runs an MCP readiness preflight, optionally runs engine boot checks, then probes launch forms in order: `opencode serve --hostname 0.0.0.0 --port 4096` → fallback `opencode web --hostname 0.0.0.0 --port 4096` → fallback bare `opencode serve`.

Under compose (`docker-compose.example.yaml`), the host binding is `127.0.0.1:4097 → container 4096` so v1 can keep port 4096.

### Verify

```sh
# Toolkit integrity (symlinks, contract integrity, agent consistency, cross-references)
bash /opt/engine/scripts/validate-toolkit.sh

# Verify MCP servers
bash /opt/engine/scripts/check-mcp.sh

# Load orchestration envelope
lean-ctx ctx_knowledge recall --key "orchestration-contract" --mode exact
```

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Where State Lives

The engine itself is stateless. Live runtime state lives in the **project-root** `session/` directory. Compose mounts the project at `/home/node/workspace`, so that folder *is* the container's global session:

- `session/contract.json`: live orchestration envelope, seeded from [`contract/contract.template.json`](contract/contract.template.json)
- `session/state.md`: append-only state log; `state.example.md` is the tracked example
- `session/archive/`: timestamped snapshots

> **LOCAL-ONLY:** `session/`, `.session/` and everything inside them are runtime state. NEVER `git add`, commit, or push them (gitignored; history grows unbounded). Archive historical state logs to `.session/` instead.

Initialize or refresh session state with:

```sh
bash /opt/engine/scripts/snapshot-contract.sh          # Seed/refresh session/contract.json + state.md
```

Layout and gitignore policy are documented in the project-root README ("Local State").

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Usage

### Orchestration Flow

Every task follows this sequence:

| Phase | Agent | Gate |
|-------|-------|------|
| **Refine** | @product-manager | Intent → GWT acceptance criteria, scope + non-goals |
| **Discuss** | Orchestrator (5-lens check) | Requirements clarified |
| **Plan** | @system-analyst (+ @software-architect review) | Impact analysis + plan produced |
| **Spec** (gate) | @system-analyst | GWT-format specs, DDD review |
| **Execute** | @developer (+ @devops-engineer, @fixer) | Implementation + tests |
| **Review** | @quality-analyst + @security-engineer (cross-model) | Code quality, security, DevOps |
| **Process** | @scrum-master | Transitions legal, DoD met, unblock BLOCKED |
| **Verify** | Quality gates | Validated JSON, conventions check |
| **Ship** | Orchestrator (+ @learner) | Post-flight protocol, lessons captured |

### Key Commands

```sh
# Load/save session state
lean-ctx ctx_session save
lean-ctx ctx_session load

# Persist decisions
lean-ctx ctx_knowledge remember key <key> value <value>

# Check blast radius before editing
ctx_impact({target: "symbolName", direction: "upstream"})

# Run the frugality ladder on any code decision
# (See agent.md §5 for the full 6-rung decision ladder)
```

Before writing **any** code, run the frugality ladder:

```text
1. Does this need to exist?       → skip it (YAGNI)
2. Standard library does it?      → use it
3. Native platform feature?       → use it
4. Already-installed dependency?  → use it
5. Can this be one line?          → one line
6. Only then: minimum code that works
```

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Architecture

The engine source lives under `engine/` and is copied to `/opt/engine/` at container build. Edit here, then rebuild to deploy.

```text
engine/
├── agent.md               ← Orchestrator instructions (instructions[0])
├── agents/                ← 16 agent instruction files
├── skills/                ← 66 engine-owned skill directories (SKILL.md + optional package.json); plugin-bundled CLI skills register at runtime and are not counted
├── commands/              ← Slash commands (impeccable)
├── contract/              ← Contract templates & schema (contract.template.json, contract.schema.json, meta-contract.template.json, state.template.md)
├── rules/                 ← rules.json + rules.schema.json (state machine, scoring, cross-model review)
├── usage/                 ← Tool usage guides (lean-ctx, graphify, context7, opencode)
├── doc/                   ← Workflow, project, and health-check docs
├── plugins/               ← vendored first-party plugin (@firecrawl/opencode, offline)
├── scripts/               ← 37 automation & validation scripts
│   ├── snapshot-contract.sh      — Envelope snapshot & archival
│   ├── validate-contract.sh      — Contract JSON validation (+ --score)
│   ├── validate-toolkit.sh       — Full toolkit integrity check
│   ├── auto-score.sh             — Automated 3-tier scoring
│   ├── persist-contract.sh       — Atomic envelope persistence
│   ├── check-conventions.sh      — Architecture convention checking
│   ├── check-cross-references.sh — 8-check link/ID integrity linter
│   ├── check-plugins.sh          — V2 plugin-path rule (rejects file://-to-file)
│   ├── check-doc-style.sh        — Doc style gate (em/en dashes, AI vocabulary, placeholders)
│   └── health-check.sh           — 6-dimension health verification
├── templates/             ← judge-prompt.md
├── .githooks/             ← pre-commit hook (bash -n sweep + cross-references + doc style)
├── opencode.json.template ← Config template (V2-native shape)
├── package.json           ← Engine metadata
└── setup.sh               ← Bootstrap (config symlinks, MCP + plugin checks)
```

### Agent Delegation Model

```text
Orchestrator (orchestrator)
  ├── @product-manager  → Requirements & acceptance criteria (read-only, reviewer model)
  ├── @system-analyst   → Planning & impact analysis (read-only)
  ├── @software-architect → Architecture review (read-only, reviewer model)
  ├── @developer        → Implementation & tests (read/write)
  ├── @devops-engineer  → CI/CD, deploy, observability (read/write)
  ├── @fixer            → Bounded fixes (read/write)
  ├── @quality-analyst  → 5-axis code review (read-only, reviewer model)
  ├── @security-engineer → Security review (read-only, reviewer model)
  ├── @scrum-master     → Process/contract enforcement, unblock (read-only, reviewer model)
  ├── @explorer / @librarian / @observer → Research & exploration (read-only)
  ├── @council          → Multi-model consensus & arbitration (read-only)
  └── @learner          → Post-execution learning
```

**Cross-model review**: executors run on the executor model (`opencode/big-pickle`); reviewers (@product-manager, @software-architect, @quality-analyst, @security-engineer, @scrum-master) run on an independent reviewer model (`sumopod/deepseek-flash`). Conflicting verdicts → `BLOCKED`, arbitrated by @council.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## State Machine

```text
INIT → PLAN → PLAN_SCORED → EXECUTE → EXECUTE_SCORED → REVIEW → REVIEW_SCORED → COMPLETE
                              ↘                      ↘                ↘
                           BLOCKED (score < 50 or retry ≥ 3)
                                 ↘
                           User intervention → retry with guidance
```

| Transition | Gate | Condition |
|-----------|------|-----------|
| INIT → PLAN | Session created | Always |
| PLAN → PLAN_SCORED | Plan produced | Always |
| EXECUTE → EXECUTE_SCORED | Implementation done | Always |
| EXECUTE_SCORED → REVIEW | Code review | Score ≥ 70 |
| REVIEW → REVIEW_SCORED | Review done | Always |
| REVIEW_SCORED → COMPLETE | All gates pass | Score ≥ 70 |
| Any → BLOCKED | Escalation | Score < 50 or retry ≥ 3 |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Scoring Pipeline

Three-tier scoring runs after every delegation:

| Tier | Method | Deduction / Range |
|------|--------|-------------------|
| 1 | Rule-based checks (start 100) | Schema -15, permissions -40, blast radius -40, writing order -15, over-engineering -15 |
| 2 | LLM-as-judge | Requirements 0-40, governance 0-30, completeness 0-20, edge cases 0-10 |
| 3 | **Combined verdict** | **≥ 70 PASS** · 50-69 RETRY (max 3) · < 50 BLOCKED |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Roadmap

- [x] Core state machine (8 forward-flow states + BLOCKED)
- [x] Three-tier scoring pipeline
- [x] 16 specialized agent instructions (scrum team)
- [x] Skill packaging (66 engine-owned SKILL.md directories; `package.json` where a skill needs deps; plugin-bundled CLI skills register at runtime and are not counted)
- [x] Cross-reference linting (scripts/check-cross-references.sh: 8-check link/ID integrity + context-standards + access-policy checks, wired into health-check lens-4, validate-toolkit.sh, pre-commit hook, CI)
- [x] Doc style gate (scripts/check-doc-style.sh: mechanical em/en dash, AI vocabulary, and placeholder checks on shipped docs, wired into health-check --check docs, validate-toolkit.sh, pre-commit hook, CI)
- [x] Project-context standards layer (skills/context-standards: load target-project context/*.md rules before edits, wired into agent.md Execute step, developer.md, quality-analyst.md, cross-reference check 7)
- [x] Mandatory lean-ctx access policy (identical Access policy line in all agents/*.md, access-layer rule in agent.md, enforced by cross-reference check 8)
- [x] V2 plugin-path rule (scripts/check-plugins.sh: rejects `file://`-to-file entries, wired into setup.sh, validate-toolkit.sh, engine boot checks)
- [x] MCP verification script (scripts/check-mcp.sh)
- [x] Template configuration (opencode.json.template: V2-native shape)
- [x] Architecture convention checking (scripts/check-conventions.sh: agent paths, JSON schema, forbidden patterns, state.md sync)
- [x] Toolkit integrity validation (scripts/validate-toolkit.sh: symlinks, contract integrity, agent consistency, cross-references)
- [x] Session archival (scripts/archive-sessions.sh: days-based cleanup with dry-run/restore)
- [x] JSON Schema enforcement (contract/contract.schema.json: Draft 2020-12, $defs, numeric constraints, valid states)
- [x] CI validation workflow (.github/workflows/validate.yml: JSON validity, `bash -n` sweep, cross-references, doc style gate, contract scoring, non-blocking conventions; activates when the project lands in a git remote)
- [x] Multi-model council consensus for high-stakes decisions
- [x] Parallel shard execution with conflict reconciliation
- [x] Automated contract persistence (scripts/auto-persist.sh)
- [x] Automated 3-tier scoring pipeline (scripts/auto-score.sh)
- [x] Agent state guard verification (scripts/state-guard.sh)
- [x] Self-repair for corrupt contracts (scripts/self-repair.sh)
- [x] Knowledge vs file drift detection (scripts/drift-detect.sh)
- [x] SDD spec gate enforcement (scripts/sdd-gate.sh)
- [x] Knowledge persistence verification (scripts/verify-knowledge.sh)
- [x] Cross-session learning feedback loop (agents/orchestrator.md, agents/learner.md)
- [ ] Skill registry publishing

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## FAQ

**Why port 4097?**
Compose binds host `127.0.0.1:4097` → container 4096 so the stable v1 stack can keep host port 4096 and both run side by side. Inside the container OpenCode always binds 4096.

**Why were the custom plugins removed?**
They target the V1 plugin API, and V2 rejects their `file://<file>` entries (`configured plugin path must be a directory`); they never loaded. They are dropped until ported to the `@opencode/plugin` V2 API; `scripts/check-plugins.sh` now enforces the no-`file`-to-`file` rule at setup, toolkit validation, and engine boot.

**How do I add a skill?**
Create a directory under `engine/skills/` containing a `SKILL.md` with frontmatter (`name`, `description`) and rebuild the image; `skills/` is symlinked into the OpenCode config directory and the skill is picked up automatically. Add a `package.json` only if the skill needs dependency metadata (28 of the current 66 have one).

**Where do project pattern standards live?**
In the target project, not here. A `context/` directory at the project root with `*.md` files is discovered and loaded via `/skill context-standards` before edits, and review verifies the files were applied. The engine itself ships no style defaults.

**Why keep the fetch MCP when Firecrawl exists?**
Different tools. `fetch` is a keyless, single-page HTTP GET with no index; Firecrawl adds an indexed primary-source search (`firecrawl_developer_search`, also keyless) plus keyed scrape/crawl/map/alexandria through the vendored plugin and `firecrawl-cli`. `fetch` stays as the zero-dependency fallback for one-off pages.

**Why does `session/` live inside the project?**
Compose mounts the project at `/home/node/workspace`, making project-root `session/` the container's global session directory. `session/contract.json` is seeded from [`contract/contract.template.json`](contract/contract.template.json). See the project-root README ("Local State") for layout and gitignore policy.

**What breaks without `pre-install/`?**
The Dockerfile installs apt/pip/npm/git packages from the store mounted as the `preinstall` build context. With an empty or missing store, installs fall back to the network, which fails in offline/air-gapped environments. Run the `populate` compose service first.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| Container crash-loops at boot | `OPENCODE_API_KEY` missing while `OPENCODE_AUTH_REQUIRED=true`; entrypoint exits 1 | Export a real key before `up`; or set `OPENCODE_AUTH_REQUIRED=false` for keyless testing |
| `MCP FAIL <name>` (executable `<bin>` not found) at boot | The server's `command` in `config/opencode.json` points at a binary not installed in the image | Fix the command or add the package to the Dockerfile; `MCP_CHECK_STRICT=false` (default) continues degraded |
| `populate` finishes instantly, skips everything | Store already populated; repeat runs skip anything present | Expected behavior, not a bug |
| Wrong-architecture build failures | `pre-install/` store tarballs match `OPENCODE_ARCH` (default `arm64`) | Override `OPENCODE_ARCH` (e.g. `x64`) and re-run `populate` for that arch |
| Boot log: "continuing without a Graphify graph" | By design: `GRAPHIFY_BUILD=if-missing` skips when the graph exists; build failures/timeouts are warnings, boot continues | Set `GRAPHIFY_BUILD=always` to force a rebuild; raise `GRAPHIFY_TIMEOUT` (default 900) if builds time out |
| `firecrawl_developer_search` refused on VPN, proxy, or cloud networks | Keyless developer search can be blocked on some networks | Set `FIRECRAWL_API_KEY` in the environment, or connect a key via `/connect` in the TUI |
| Every `firecrawl_alexandria` run asks for confirmation | By design: the config permission sets `effect: ask` for alexandria | Confirm per run, or change the permission to `allow` in `config/opencode.json` if your policy allows |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Contributing

The stack is developed in place; the v1 repository (`../opencode`) is the versioned source of truth, and this folder is intentionally not a git repository.

When this folder lands in a remote, the gates apply automatically:

1. `.github/PULL_REQUEST_TEMPLATE.md` structures the PR description
2. `engine/.githooks/pre-commit` gates each commit (enable: `git config core.hooksPath engine/.githooks`)
3. `.github/workflows/validate.yml` runs on push and pull_request

Before handing off any change, run:

```sh
bash engine/scripts/validate-toolkit.sh
```

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## License

Internal workflow tooling. This copy ships no license file and is not distributed externally; the v1 repository remains the versioned source of truth.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Acknowledgments

- [Best-README-Template](https://github.com/othneildrew/Best-README-Template) by [@othneildrew](https://github.com/othneildrew): README structure
- [Img Shields](https://shields.io): badge generation

<p align="right">(<a href="#readme-top">back to top</a>)</p>
