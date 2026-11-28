# Workspace Index Routing - rag, lean-ctx, ast-grep

Three retrieval layers serve agents in this environment. rag is the semantic
workspace index for discovery; lean-ctx is the precision layer; ast-grep adds
structural AST search. No embedding model runs in this stack: rag is SQLite
FTS5 plus hashed vectors, lean-ctx is lexical/symbol/callgraph, ast-grep is
syntax pattern matching.

## Layer comparison

| | rag (rag_search) | lean-ctx | ast-grep |
| --- | --- | --- | --- |
| scope | whole workspace, git-independent | project code intelligence | code syntax patterns |
| strength | broad discovery across docs, feedback, sandboxes | exact symbols, callers, blast radius | matches a shape no regex can express |
| refresh | rag_index (incremental, hash-based) | live index | none: patterns run on the tree |
| failure mode | silently stale; stale hits look authoritative | misses cross-repo docs | verbose patterns on odd formatting |

## Routing

- Concept questions, project conventions, unfamiliar-area discovery:
  rag_search first, then verify hits against the source with ctx_read.
- Workspace-only content (feedback files, sandbox artifacts, session
  notes): rag_search only.
- Exact symbols, callers, blast radius: never rag. Use lean-ctx
  ctx_search and ctx_callgraph; semantic indexes are not precision tools.
- Syntax-shaped questions (every call site matching a shape, a JSX prop, a
  function signature): ast-grep with a structural pattern, not grep and not
  rag. ast-grep is a CLI baked into the image and pinned in
  pre-install/versions.lock; run patterns with
  `ast-grep run -p '<pattern>' -l <lang>` or a YAML rule file.

## Refresh discipline

After each merge: fetch and fast-forward the canonical clone, then run
rag_index once (it is hash-based and skips unchanged files).

## Observed failure history (why this doc exists)

- rag ran for days without a refresh; thousands of stale files made
  answers authoritative-sounding and wrong.
- Treat hits as discovery anchors, never as verified facts: open the
  cited file region before quoting or editing.
- An earlier embedding-backed AST index was removed from the stack: it
  pulled torch and transformers into the image for local embeddings. The
  three layers above answer the same questions without an embedding model.
