<!-- lean-ctx-owned: PROJECT-LEAN-CTX.md v2 -->

<!-- omit from toc -->
# lean-ctx — Context Engineering Layer

> **Repository**: [github.com/yvgude/lean-ctx](https://github.com/yvgude/lean-ctx) — context-aware MCP tools for AI agents
> **30 tools** across 12 categories: read, edit, search, tree, shell, knowledge, session, call, multi_read, discover_tools, compress, graph

Token-efficient MCP tools for reading, searching, and persisting context. Replaces native `Read`/`Grep`/`Shell` with cached reads, compressed output, and cross-session knowledge.

**Session savings: ~78% token reduction ($0.78/session avg).** Cache hit rates above 30% mean zero-cost re-reads (~13 tok each).

[![lean-ctx][leanctx-shield]][leanctx-url] [![Version][version-shield]][version-url]

<a id="readme-top"></a>

---

## Table of Contents
1. [Registered Tools (always available)](#1-registered-tools-always-available)
2. [Use Case Matrix — When to Use What](#2-use-case-matrix--when-to-use-what)
3. [ctx_read Mode Selection](#3-ctx_read-mode-selection)
4. [Batch Operations — ctx_multi_read](#4-batch-operations--ctx_multi_read)
5. [Knowledge Management — ctx_knowledge](#5-knowledge-management--ctx_knowledge)
6. [Session Management — ctx_session](#6-session-management--ctx_session)
7. [Tool Discovery — ctx_discover_tools + ctx_call](#7-tool-discovery--ctx_discover_tools--ctx_call)
8. [Compression Strategy](#8-compression-strategy)
9. [Cost Awareness — ctx_metrics](#9-cost-awareness--ctx_metrics)
10. [Full Tool Inventory — All lean-ctx Capabilities](#10-full-tool-inventory--all-lean-ctx-capabilities)
11. [Quick Reference — Mini Pattern Card](#11-quick-reference--mini-pattern-card)
12. [Common Pitfalls](#common-pitfalls)
13. [Field Guide — Effective Usage Patterns](#13-field-guide--effective-usage-patterns-leanctxcomdocs)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 1. Registered Tools (always available)

| Tool                          | Replaces              | Best For                                          | Avg Savings |
|-------------------------------|-----------------------|---------------------------------------------------|:-----------:|
| `ctx_read(path, mode)`        | `Read` / `cat`        | Cached file reads — ALL file reads                |     70%     |
| `ctx_multi_read(paths, mode)` | Multiple `Read` calls | **Batch read** 2-10 files in one call             |   70% × N   |
| `ctx_search(pattern, ext)`    | `Grep` / `rg`         | Regex code search (.gitignore-aware)              |     78%     |
| `ctx_tree(path, depth)`       | `ls` / `find`         | Directory structure overviews                     |  2% (fast)  |
| `ctx_edit(path, old, new)`    | `Edit`                | Search-and-replace when `Read` unavailable        |      —      |
| `ctx_knowledge(action, …)`    | —                     | Cross-session facts, patterns, decisions (see §5) |      —      |
| `ctx_session(action, …)`      | —                     | Session persistence and resume (see §6)           |      —      |

**Rule of thumb:** If there's a `ctx_*` for it, use it. Native tools trigger permission prompts, bypass caching, and increase token cost.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 2. Use Case Matrix — When to Use What

| You want to…           | Use this                         | With…                                                  |
|------------------------|----------------------------------|--------------------------------------------------------|
| Read a file            | `ctx_read`                       | `mode=auto` for most files, `mode=map` for config/docs |
| Read multiple files    | `ctx_multi_read`                 | Array of paths, one mode for all or mixed              |
| Check file structure   | `ctx_read`                       | `mode=map` (exports, deps, constants — ~13 tok)        |
| Check API surface      | `ctx_read`                       | `mode=signatures` (methods, params, types only)        |
| Search codebase        | `ctx_search`                     | `pattern` + `ext` filter                               |
| Explore directory      | `ctx_tree`                       | `depth=2` for project root, `depth=4` for src/         |
| Run a command          | `ctx_shell`                      | Compressed by default; `raw=true` for full output      |
| Save decisions         | `ctx_knowledge`                  | `action=remember` with `category` + `key`              |
| Retrieve past work     | `ctx_knowledge`                  | `action=recall` with `query` (semantic search)         |
| Resume after restart   | `ctx_session`                    | `action=load` (auto-latest) or `action=resume`         |
| Check session state    | `ctx_session`                    | `action=status` (files cached, tokens used)            |
| Batch multiple edits   | `ctx_multi_read` + native `edit` | Read once, edit multiple sections                      |
| Discover tools         | `ctx_discover_tools`             | `query="session"` to find all session-related tools    |
| Call unregistered tool | `ctx_call`                       | `{name:"ctx_metrics", arguments:{action:"status"}}`    |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 3. ctx_read Mode Selection

Optimize cache hit rate by matching mode to intent:

| Mode         | When                                  |  Token Cost   | Cache Hit Rate |
|--------------|---------------------------------------|:-------------:|:--------------:|
| `auto`       | **Default** — let lean-ctx decide     |    varies     |      High      |
| `full`       | Files you're about to **edit**        |   full file   |      High      |
| `map`        | Configs, docs, context-only files     |    ~13 tok    |  **Highest**   |
| `signatures` | Checking API surface (methods, types) |     small     |      High      |
| `diff`       | After edits — see what changed        | changed lines |      Low       |
| `aggressive` | Reference files, secondary context    |    minimal    |     Medium     |
| `entropy`    | Finding high-complexity regions       |     small     |      Low       |
| `task`       | Task-relevant filtering (IB-filtered) |    varies     |     Medium     |
| `reference`  | Quote-friendly minimal excerpts       |    minimal    |      High      |
| `lines:N-M`  | Specific range you already know       |  that range   |  Low (fresh)   |

**Cache optimization tips:**

- Use `map` for files you DON'T plan to edit (configs, docs, pom.xml, gitignore) — highest cache hit rate
- Use `signatures` for checking method signatures or class structure

- Use `full` only for files you're actively editing
- Re-reading an unchanged file costs ~13 tok with any mode — always prefer `ctx_read` over `Read`

- Fresh reads (`fresh=true`) bypass cache — only when you know the file changed externally

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 4. Batch Operations — ctx_multi_read

Instead of 3+ sequential `ctx_read` calls, batch them:

```text
ctx_multi_read(paths=["pom.xml", "src/main/.../pom.xml", "README.md"], mode="map")

ctx_multi_read(paths=["Controller.java", "Service.java", "Repository.java"], mode="signatures")

```
**When to batch:**

- Reading related files together (controller + service + repository for one feature)
- Scanning build/config files across modules

- Reading orchestration documents (AGENTS.md + STATE.md + PROJECT.md)
- Reading all files in a small directory

Each call still uses cache — batch doesn't force fresh reads.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 5. Knowledge Management — ctx_knowledge

Cross-session persistence. Core of the orchestration envelope system.

### remember — persist a fact

```text
ctx_knowledge action=remember category=architecture|testing|deployment|conventions|gotchas

                   key="fact-slug" value="The fact content"

                   confidence=0.8   # optional, default 0.8

```
**Used for:** Architecture decisions, gotchas discovered during work, deployment patterns, test conventions.

### recall — retrieve past knowledge

```text
ctx_knowledge action=recall query="orchestration-contract"

                   mode=auto|exact|semantic|hybrid

```
**Modes:**

- `exact` — lexical match only (fast)
- `semantic` — embeddings-based meaning match (better for recall)

- `hybrid` — both (default when embeddings available)
- `auto` — hybrid if embeddings, else exact

### patterns — reusable solutions

```text
ctx_knowledge action=pattern key="test-base-class"

                   pattern_type=naming|structure|testing|error-handling

                   value="AbstractGenericServiceTest with 12 hooks"

```
### Pattern: Orchestration Contract Load/Update

```text
# Every session start:

recall --query "orchestration-contract"   # load state

# After each phase:

remember key orchestration-contract value "<updated JSON>"  # persist

```
<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 6. Session Management — ctx_session

Cross-session memory for conversation resume.

| Action     | When                                    | Example                                      |
|------------|-----------------------------------------|----------------------------------------------|
| `save`     | Before session end, after checkpoints   | `action=save`                                |
| `load`     | After restart — restore latest session  | `action=load` (auto-latest)                  |
| `resume`   | Full resume with state inference        | `action=resume`                              |
| `status`   | Check cached files, tokens, session age | `action=status`                              |
| `task`     | Set working context label               | `action=task value="refactor-auth"`          |
| `finding`  | Log a finding for next session          | `action=finding value="key insight"`         |
| `decision` | Log a decision for next session         | `action=decision value="use hexagonal arch"` |

**Session resume pattern (post-flight protocol step 6 in AGENTS.md):**

```text
# Before session end

lean-ctx ctx_session save

# After restart

lean-ctx ctx_session load           # restores ~400 tok of context

lean-ctx ctx_knowledge recall --query "orchestration-contract"  # load envelope

```
<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 7. Tool Discovery — ctx_discover_tools + ctx_call

Not all lean-ctx tools are registered as MCP tools. Use `ctx_call` to access them:

```text
# Discover tools by capability

lean-ctx ctx_discover_tools query="session"

  → returns: ctx_session, ctx_context, ctx_metrics, ctx_overview

# Call any discovered tool

lean-ctx ctx_call name="ctx_metrics" arguments='{"action":"status"}'

lean-ctx ctx_call name="ctx_context" arguments='{"action":"status"}'

lean-ctx ctx_call name="ctx_overview" arguments='{"task":"current task description"}'

lean-ctx ctx_call name="ctx_graph" arguments='{"action":"status"}'

lean-ctx ctx_call name="ctx_plan" arguments='{"mode":"budget","files":["..."]}'

```
<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 8. Compression Strategy

The `compress` tool is NOT a lean-ctx tool — it's a native context management tool. Use it when:

| Scenario                      | Compress What                        | Why                                               |
|-------------------------------|--------------------------------------|---------------------------------------------------|
| Research completed            | All research messages                | Replace raw exploration with crystallized summary |
| Implementation done           | Back-and-forth debug cycles          | Keep only findings, drop failed attempts          |
| Phase transition              | Previous phase messages              | Start fresh for next phase                        |
| Context > 50% used            | Oldest closed sections               | Free space for new work                           |
| Before delegation to subagent | Conversation before delegation point | Clear context for subagent return                 |

**Compression pattern (from orchestration workflow):**

```text
compress topic="Auth System Exploration"

         content=[{startId:"m0001", endId:"m0012", summary:"..."}]

```
Good summary = captures user intent + file paths + decisions + constraints. Fidelity over brevity — a compressed block should be self-contained.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 9. Cost Awareness — ctx_metrics

```text
ctx_call name="ctx_metrics" arguments='{"action":"status"}'

```
Returns:

- Session token savings (absolute + percentage)
- Cost saved in USD

- Per-tool breakdown (calls, tokens, savings %)
- File cache hit rate

- CEP Score (target: >80/100)
- Compression pipeline stats

**Target metrics:**

- Cache hit rate: >30% (currently 17% — use `map`/`signatures` more)
- CEP Score: >80/100 (currently 64 — diversify modes)

- Compression ratio: >20% (currently 22% — okay)

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 10. Full Tool Inventory — All lean-ctx Capabilities

**28+ tools total.** 10 registered as MCP tools (always available). 18+ more accessible via `ctx_call`. Organized by category with project-specific use case mapping.

| Category      | Tool                  | Registered?  |              Access              | Our Project Use Case                                            |
|---------------|-----------------------|:------------:|:--------------------------------:|-----------------------------------------------------------------|
| **Read**      | `ctx_read`            |   ✅ Direct   |             10 modes             | Read ANY file — Java source, configs, docs, gitignore           |
|               | `ctx_multi_read`      |   ✅ Direct   |              Batch               | Read controller+service+repository for one feature              |
|               | `ctx_outline`         | ❌ `ctx_call` |       Symbols + signatures       | Quick API surface scan of a class (fewer tok than `signatures`) |
|               | `ctx_expand`          | ❌ `ctx_call` |    Archived output retrieval     | Recover archived tool output that was compressed                |
| **Write**     | `ctx_edit`            |   ✅ Direct   |        Search-and-replace        | Edit files when native `Read` unavailable                       |
| **Search**    | `ctx_search`          |   ✅ Direct   |     Regex, .gitignore-aware      | Find classes, patterns across codebase                          |
|               | `ctx_semantic_search` | ❌ `ctx_call` |        BM25 + embeddings         | "Find where we handle receipt parsing" — meaning, not keywords  |
|               | `ctx_artifacts`       | ❌ `ctx_call` |      BM25 artifact registry      | Search indexed build/test artifacts                             |
| **Directory** | `ctx_tree`            |   ✅ Direct   |          Depth control           | Project structure overview                                      |
| **Knowledge** | `ctx_knowledge`       |   ✅ Direct   |     remember/recall/pattern      | **Orchestration envelope**, architecture decisions, gotchas     |
| **Session**   | `ctx_session`         |   ✅ Direct   |         save/load/resume         | **Post-flight protocol**, cross-session resume                  |
|               | `ctx_metrics`         | ❌ `ctx_call` |         Token/cost stats         | Check session savings, cache hit rate, CEP score                |
|               | `ctx_context`         | ❌ `ctx_call` |          Session state           | What files are cached? How old is session?                      |
|               | `ctx_overview`        | ❌ `ctx_call` |        Task-relevant map         | **Session start** — auto-generated project map                  |
|               | `ctx_gain`            | ❌ `ctx_call` |        Efficiency report         | Summarize session token savings                                 |
| **Graph**     | `ctx_graph`           | ❌ `ctx_call` | Code graph: build/status/related | File dependency graph, enriched symbol relationships            |
|               | `ctx_impact`          | ❌ `ctx_call` |         Impact analysis          | "What breaks if I change this file?" — complements lean-ctx     |
|               | `ctx_architecture`    | ❌ `ctx_call` |    Clusters, layers, overview    | High-level arch diagram generation                              |
|               | `ctx_callgraph`       | ❌ `ctx_call` |         Callers/callees          | Standard call chain trace                                       |
|               | `ctx_prefetch`        | ❌ `ctx_call` |          Prewarm cache           | Before large refactor — warm cache for blast radius files       |
| **Compress**  | `ctx_compress`        | ❌ `ctx_call` |     Checkpoint conversations     | **Context pressure** — replace raw chat with summary            |
|               | `ctx_benchmark`       | ❌ `ctx_call` |         Mode comparison          | Test which compression mode works best for a file               |
|               | `ctx_analyze`         | ❌ `ctx_call` |     Entropy + recommendation     | "What mode should I use for this file?"                         |
|               | `ctx_fill`            | ❌ `ctx_call` |        Budget-aware fill         | Fill context up to token budget with optimal compression        |
|               | `ctx_compile`         | ❌ `ctx_call` |      Knapsack optimization       | Build minimal context package from file list                    |
|               | `ctx_compress_memory` | ❌ `ctx_call` |        Compress CLAUDE.md        | Compress config files preserving code/URLs/patterns             |
|               | `ctx_res`             | ❌ `ctx_call` |      Compress LLM response       | Strip filler from long LLM responses                            |
|               | `ctx_discover`        | ❌ `ctx_call` |      Shell history analysis      | Find missed compression opportunities in past commands          |
| **Agent**     | `ctx_agent`           | ❌ `ctx_call` |     Multi-agent coordination     | Register/read/pass messages between sub-agents                  |
|               | `ctx_share`           | ❌ `ctx_call` |       Share file contexts        | Push cached files to another agent's context                    |
|               | `ctx_task`            | ❌ `ctx_call` |        Task orchestration        | Create/update/track sub-agent tasks                             |
|               | `ctx_cost`            | ❌ `ctx_call` |       Per-agent/tool cost        | "Which agent spent the most tokens?"                            |
| **Review**    | `ctx_review`          | ❌ `ctx_call` |       Code review + impact       | Automated review with test discovery                            |
| **Planning**  | `ctx_plan`            | ❌ `ctx_call` |     Context budget planning      | "Which files to load for a 10K token budget?"                   |
| **Dedup**     | `ctx_dedup`           | ❌ `ctx_call` |         Cross-file dedup         | Find duplicate code blocks across files                         |
| **PR**        | `ctx_pack`            | ❌ `ctx_call` |         PR context pack          | Changed files + related tests + impact summary                  |
| **Prefetch**  | `ctx_preload`         | ❌ `ctx_call` |      Task-relevant loading       | Load all files relevant to a task upfront                       |

### Top 5 Underused Tools for Our Project

| Tool               | Missed Opportunity                                                           | When to Start Using              |
|--------------------|------------------------------------------------------------------------------|----------------------------------|
| `ctx_overview`     | ~0 tok session-start project map — replaces manual STATE.md+PROJECT.md reads | **Every session start**          |
| `ctx_architecture` | Auto-generate arch diagrams from code graph                                  | Before complex refactors         |
| `ctx_compile`      | Optimal context package for subagent delegation                              | Before dispatching to @developer |
| `ctx_prefetch`     | Prewarm cache for refactor blast radius files                                | Before any large multi-file edit |
| `ctx_callgraph`    | Quick call chain without lean-ctx overhead                                   | When investigating a bug         |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## 11. Quick Reference — Mini Pattern Card

```text
# Session start

ctx_call name="ctx_overview" arguments='{"task":"current task"}'  # project map

ctx_knowledge recall --query "orchestration-contract"             # load envelope

ctx_read STATE.md mode=map            # current position (13 tok)

ctx_read PROJECT.md mode=map          # project vision

# Files you'll edit

ctx_read File.java mode=full          # editable read

ctx_multi_read paths=[A,B,C] mode=signatures  # batch read APIs

# During work

ctx_shell "cat session/state.md"    # check session state

ctx_search pattern="class X" ext=.java  # find classes

# Before large refactor

ctx_call name="ctx_prefetch" arguments='{"target":"symbolName","direction":"upstream"}'

ctx_call name="ctx_callgraph" arguments='{"name":"methodName","direction":"callers"}'

# After work

ctx_knowledge remember category=gotchas key="foo-pattern" value="..."

ctx_session save                      # persist conversation

ctx_call name="ctx_metrics" arguments='{"action":"status"}'  # check costs

```
> **Cache beats fresh.** An unchanged file at ~13 tok beats any native read. Use mode=map for everything you don't actively edit.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

---

## Common Pitfalls

### Using `bash` instead of `ctx_shell`
Always use `lean-ctx ctx_shell` for shell commands. Native `bash` triggers permission prompts and blocks automation. This is enforced by SHELL_001 in project rules.

### Forgetting `--fresh` on re-reads
`ctx_read` caches aggressively (~13 tok for unchanged files). If the file changed on disk (e.g., edited by another tool), pass `fresh=true` to force a re-read:
```
lean-ctx ctx_read --path "file.java" --fresh true
```

### Not using `ctx_multi_read` for batches
Reading 10 files individually costs 10x the token overhead. Batch them:
```
lean-ctx ctx_multi_read --paths '["a.java","b.java","c.java"]'
```

### Over-relying on `full` mode
Use mode compression for large files:
- `signatures` — class/method signatures only
- `map` — outline structure
- `lines:N-M` — specific line range
- `diff` — show changes from last read

### Forgetting `ctx_session save` after checkpoints
Always save after important milestones:
```
lean-ctx ctx_session save
```
This survives OpenCode restarts and enables session resume.

<p align="right">(<a href="#readme-top">back to top</a>)</p>

[leanctx-shield]: https://img.shields.io/badge/lean--ctx-Context%20Engineering-7B68EE?style=for-the-badge
[leanctx-url]: https://github.com/yvgude/lean-ctx
[version-shield]: https://img.shields.io/badge/Version-latest-7B68EE?style=for-the-badge
[version-url]: #
## 13. Field Guide — Effective Usage Patterns (leanctx.com/docs)

> Distilled from the official docs (reviewed 2026-11-07, runtime 3.12.2). These patterns separate using lean-ctx from using it effectively.

### 13.1 The discovery → zoom → edit ladder

Never open a file at `full` just to find something. Descend only as deep as the task needs:

1. **Discover**: `ctx_search` (regex `pattern` / semantic `query` / symbol `name` — distinct actions) or `ctx_compose` for execution flows
2. **Survey**: `ctx_read mode=map` (structure) or `mode=signatures` (API surface)
3. **Zoom**: `ctx_read mode=lines:N-M, fresh=true` using a range returned by search/signatures — never guess line numbers
4. **Edit**: recover exact text (`raw: true` or `full`) before writing; `mode=anchored` provides line/hash anchors for patch edits
5. **Verify**: re-read the edited region (`lines:N-M`) — a stale anchor is a reason to re-read, never to force an overwrite

**Mode overrides to know**: instruction files (`AGENTS.md`, `SKILL.md`, `CLAUDE.md`, …) are ALWAYS delivered in full regardless of mode. Files lean-ctx has learned (you edited them) are re-served in full too (`[mode overridden: map -> full, reason=learned]`). Expect larger responses on your own working set.

### 13.2 Extended read modes

| Mode | Behavior |
|------|------|
| `lines:5,10-20` | multiple ranges in one read |
| `lines:-20` | last 20 lines |
| `diff` | changes since the READ CACHE (not git HEAD — use `git diff` for repo changes) |
| `anchored` / `anchored:N-M` | text with line/hash refs for patch edits |
| `density:0.40` | target-density compressed view (lossy — recover before exact edits) |
| `raw` / `full-compact` | verbatim / headerless trimmed text |

`diff` mode is the cheap re-read after bulk changes: one call shows what moved since your last read instead of re-reading whole files.

### 13.3 Three stores — know where things live

| Store | Holds | Recover with |
|------|------|------|
| Read cache | prior representations | unchanged re-read → ~13 tok stub |
| Output archive | large tool output, outside the prompt | `ctx_expand` with the returned archive/job id — supports `search`, line ranges, `head`/`tail` |
| Project knowledge | durable facts and decisions | `ctx_knowledge recall` |

A cache hit is not knowledge; an archive is not a live repo view. Archive handles expire — persist durable evidence with `ctx_knowledge remember`.

### 13.4 Shell discipline

- **A compressed success-looking summary is NOT the exit status. Check both** — recover omitted output when diagnosing a failure.
- Long-running work: `ctx_shell` returns a `job_id`; poll/act with `background_action` + that exact id; recover results via `ctx_expand` (accepts `shell_*` job ids). Do not launch duplicate jobs because the first call returned early.
- A blocked command is NOT made permissible by switching tools — execution tools enforce the same allowlist. Reroute through the sanctioned path (gate-first rule, agent.md §6).
- The child shell parses the command — prefer single simple commands or POSIX syntax over shell-specific operators.

### 13.5 Search & code intelligence

- `ctx_search` has three DISTINCT actions: regex (`pattern`), semantic (`query`), symbol (`name`) — pick explicitly; semantic results depend on index freshness.
- Build/rebuild indexes with `ctx_index` (the old `ctx_search action=reindex` is not accepted in current contracts).
- Callers/callees/impact: `ctx_callgraph` / `ctx_impact` — static extraction misses dynamic imports and generated code; treat HIGH/CRITICAL as warnings to inspect, not blockers.

### 13.6 Context controls

- `ctx_control` (include/exclude/pin/view/priority) shapes planning and retrieval — pin the narrowest source for the task lifetime, unpin when the task changes.
- `ctx_ledger` inspects and prunes retained context pressure. Exclusions are NOT a security boundary — use policy/jail when access must be prevented.

### 13.7 Golden rules

1. Never edit from a compressed view — recover the original, confirm it is current, then edit.
2. Never write summaries, omission markers, or archive notices into source code.
3. Re-read after any conflicting edit instead of forcing stale anchors.
4. Batch with `ctx_multi_read` (2–10 files, one call) instead of N reads.
5. Check exit status and compressed output separately.

