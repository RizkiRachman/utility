# Semantic Index Routing - rag and cocoindex-code in this workspace

Two semantic indexes serve agents in this environment. They fail in
different ways and this doc defines which one answers which question,
and when each must be refreshed.

## The two indexes

| | rag (rag_search) | cocoindex-code (ccc search) |
| --- | --- | --- |
| scope | the whole workspace, git-independent | nested git repos it can see from the workspace root |
| strength | broad discovery across docs, feedback, sandboxes | AST-aware code search over indexed repos |
| refresh | rag_index (incremental, hash-based) | ccc index (incremental) |
| failure mode | silently stale; stale hits look authoritative | silently empty; unindexed paths return fuzzy misses |

## Routing

- Product source (engine scripts, engine docs): ccc search first for
  symbol-level questions, rag_search for concept questions. Both must
  be able to see the canonical clone below.
- Workspace-only content (feedback files, sandbox artifacts, session
  notes): rag_search only.
- Exact symbols, callers, blast radius: neither. Use lean-ctx
  ctx_search and ctx_callgraph; semantic indexes are not precision
  tools.

## Canonical local clone

/home/node/workspace/repos/utility is the durable local copy of the
product repository and the scope ccc indexes. Sandbox copies under
sandbox/ are throwaway and get pruned; never treat them as the
reference. After each merge: fetch and fast-forward the canonical
clone, then run ccc index from the workspace root.

## Observed failure history (why this doc exists)

- rag ran for days without a refresh; thousands of stale files made
  answers authoritative-sounding and wrong.
- ccc shipped registered but unindexed; search returned plausible but
  unrelated hits, which reads exactly like success until checked.
- A gitignore policy at the workspace root hides non-repo trees from
  ccc; only nested git repos under repos/ are discoverable. Content
  outside repos/ belongs to rag alone.
