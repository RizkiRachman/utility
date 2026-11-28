# Workspace Index Routing - rag in this workspace

One semantic index serves agents in this environment (rag). Precision
questions never route to it.

## What rag is for

| | rag (rag_search) |
| --- | --- |
| scope | the whole workspace, git-independent |
| strength | broad discovery across docs, feedback, sandboxes |
| refresh | rag_index (incremental, hash-based) |
| failure mode | silently stale; stale hits look authoritative |

## Routing

- Concept questions, project conventions, unfamiliar-area discovery:
  rag_search first, then verify hits against the source with ctx_read.
- Workspace-only content (feedback files, sandbox artifacts, session
  notes): rag_search only.
- Exact symbols, callers, blast radius: never rag. Use lean-ctx
  ctx_search and ctx_callgraph; semantic indexes are not precision
  tools.

## Refresh discipline

After each merge: fetch and fast-forward the canonical clone, then run
rag_index once (it is hash-based and skips unchanged files).

## Observed failure history (why this doc exists)

- rag ran for days without a refresh; thousands of stale files made
  answers authoritative-sounding and wrong.
- Treat hits as discovery anchors, never as verified facts: open the
  cited file region before quoting or editing.
