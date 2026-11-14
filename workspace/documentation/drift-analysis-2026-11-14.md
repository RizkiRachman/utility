<!-- omit from toc -->
# Drift analysis: enforcement workflow, 2026-11-14

Scope: the pieces that make agent work enforceable and repeatable across sessions: the engine agents and scripts, the MCP servers, skills and plugins, the RAG and CocoIndex retrieval layer, and the configuration that binds them. Method: run the engine's own checks, exercise every retrieval path by hand, and compare documented claims against the running system.

## What is working well

- The engine's own checks catch real drift. `check-cross-references.sh` flagged nine engine files carrying legacy `bash /opt/engine` gate phrasing; all nine were real and all are fixed in this change.
- The RAG server runs fully offline (local hashed n-gram embeddings, no network) and its search plus chunk-read paths tested correct.
- CocoIndex completed its first full index (743 files, 20,379 chunks) and its semantic search returned the right files for concept-level queries, including code merged the same day.
- The MCP fleet is consistent with the documented set: six servers (lean-ctx, Context7, fetch, rag, OpenUI, CocoIndex Code), matching the opencode config.

## Fixed on 2026-11-14

| # | Area | Finding | Fix |
| --- | --- | --- | --- |
| F1 | RAG server | Incremental re-index failed with `too many SQL variables`: the purge path built unbounded `IN (...)` clauses, and a large stale set (2,534 files, about 40k chunk ids) exceeded SQLite's host-parameter cap | Batched every `IN (...)` list to 500 parameters (`SQL_PARAM_BATCH`) in `agents/opencode/rag/server.js` |
| F2 | RAG server | One unreadable file (root-owned `pre-installer/apt/lock`) aborted the whole index run with EACCES | `loadFile` now skips unreadable files and reports them as `skipped_unreadable` |
| F3 | RAG index | Index last built 2026-11-09; searches missed newer files | Rebuilt: 861 files, 14,793 chunks, stale set cleared; re-index verified working through the MCP tool |
| F4 | CocoIndex | First run resolved the project root to `/` with a root-owned DB directory, so every query failed with `unable to open database file` | Initialized the project in the workspace (`ccc init`); daemon now indexes `workspace/` only |
| F5 | Engine docs | Nine agent and workflow docs still showed the legacy `bash /opt/engine/...` invocation that the shell policy denies | Rewrote to the sanctioned `lean-ctx ctx_shell /opt/engine/...` form in the engine source and the runtime copy |
| F6 | opencode README | Version badges stale: opencode 2.2.5 vs 2.3.0 in `pre-install/versions.lock`; lean-ctx 3.12.0 vs 3.12.4 installed | Badges updated to the lockfile versions |

## Open items

| # | Area | Finding | Suggested next step |
| --- | --- | --- | --- |
| O1 | Gitea access | `GITEA_TOKEN` set in the environment is rejected by the instance (`invalid username, password or token`); basic auth works | Mint a fresh token with repo + PR scopes, store it in the host `.env`, and treat it like the other keys; rotate the shared admin credential |
| O2 | Config durability | Workspace-root files are wiped by host re-provisioning (the project `opencode.json` was lost twice on this date); the global `~/.config/opencode/opencode.json` is a read-only bind mount | Keep the source of truth for provider config in the repo and have the host inject it; agents treat workspace-root config as disposable |
| O3 | Agent shell allowlist | `opencode`, inline code execution (`node -e`), `mount`, and `strings` are blocked for agent shells, so agents cannot restart or version-probe the OpenCode service themselves | Acceptable for safety; document a host-side runbook for the restart step agents cannot do |
| O4 | drift-detect.sh | The script looks for the contract at `/opt/session/contract.json`, which is not where sessions live | Point the script at the real session directory or make the path configurable |
| O5 | CocoIndex telemetry | The scarf usage ping ignores `DO_NOT_TRACK`; the working opt-out is `COCOINDEX_DISABLE_USAGE_TRACKING=1` (verified against `core.abi3.so`) | Set it for every launch path (MCP env done); consider proposing it upstream as a documented variable |
| O6 | Duplicate retrieval layers | RAG (whole workspace, FTS plus vectors) and CocoIndex (code-focused, AST-aware) overlap on most files | Keep both for now: RAG covers prose and config, CocoIndex covers code structure. Worth a doc note in each README so agents pick the right one |
| O7 | Placeholder directories | `tools/`, `documentation/`, and the infrastructure payload dirs are empty; nothing drifts in them yet | Documented in this change; revisit when the first payload lands |

## Notes for the next session

- Both retrieval layers are re-built and tested: RAG via `rag_index` (now safe for bulk purges), CocoIndex via the daemon (complete, 743/743 files).
- The patched RAG code runs from disk immediately for CLI use; a restarted MCP server picks it up too (verified after the engine refresh).
- The repo layout: this workspace is the `workspace/` directory of `development-tools/utility` on Gitea. Repo-root files (compose, CI, top-level README) are outside the agent-visible tree.
