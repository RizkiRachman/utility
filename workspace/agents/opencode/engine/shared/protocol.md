# Shared Agent Protocol

Binding on every agent. Read this file at session start; the short references in agent instruction files point here.

## 1. Envelope recall (exact)

Resolve `<task_id>` from `session.task_id` in `session/contract.json` first, then recall:

`ctx_knowledge recall key="orchestration-contract:<task_id>" mode="exact"`

This is an MCP tool call, never a shell command. A bare un-namespaced legacy key is a one-time compatibility fallback only when the namespaced recall misses. If the envelope does not exist, create it from `contract/contract.template.json` with `state=INIT`. Record a `memory_bootstrap` receipt before the first delegation.

## 2. Envelope purpose

`contract/contract.template.json` is the single source of truth for state, decisions, scores, retry context, and outputs. It persists across sessions. Never write `contract.state` directly: use `scripts/transition.sh --to STATE --agent NAME --evidence ID`, the only sanctioned mutator.

## 3. Access policy (mandatory)

All tool access flows through lean-ctx: `ctx_read` / `ctx_glob` / `ctx_search` for reads and discovery, `ctx_shell` for commands, `ctx_impact` before edits, `ctx_knowledge remember` with a category for persistence, `ctx_session` for saves. File edits use the host native edit tool. Library documentation uses context7. Native `read` / `grep` / `bash` bypasses are governance violations.

## 4. Persistence

After every transition, delegation, scoring, and phase completion, persist the envelope with `lean-ctx ctx_knowledge remember key orchestration-contract:<task_id> value <updated JSON>` and sync `session/state.md`. Shell writes to `contract.json`, `.env*`, `opencode.json`, `.session/`, and the audit and score ledgers are denied by `rules.json -> enforcement.shell_policy`.

## 5. Post-flight (before commit)

Run `ctx_impact` on changed symbols, `ctx_delta()` to verify scope, persist knowledge, and update `session/state.md`. Docs-only changes skip impact and change detection; config-only changes skip impact. Never commit `session/`, `.session/`, `.env`, or credentials.
