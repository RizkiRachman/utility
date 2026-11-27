# FalkorDB Knowledge Graph (`falkordb` MCP)

Governance fact graph: entities (decisions, PRs, findings, files, lessons, failure classes) and typed relations, queried with OpenCypher. The MCP server is a dumb Cypher bridge - no AI in the loop; the calling agent writes the queries.

## Stack

| Piece | Image | Notes |
|---|---|---|
| Graph DB | `falkordb/falkordb:latest` | Redis-module graph DB; RDB persistence to the mounted `/data` volume |
| MCP server | `falkordb/mcpserver:latest` | stdio transport (explicit: the image bakes `MCP_TRANSPORT=http`, so the command passes `-e MCP_TRANSPORT=stdio`); tools: `query_graph`, `query_graph_readonly` (parameterized Cypher), `create_graph`, `delete_graph`, `list_graphs` |

## Files

| File | Purpose |
|---|---|
| `kg-up.sh` | Pull both images, create the `kg-net` docker network, start `kg-falkordb` (idempotent) |
| `kg-down.sh` | Remove containers + network; keeps the data directory |
| `config-entry.json` | Canonical `.mcp.servers.falkordb` snippet (registered centrally in `config/opencode.json`) |

## Setup

```bash
bash ai/mcp/falkordb/kg-up.sh
```

- Creates the `kg-net` docker network, starts `kg-falkordb` (host port `127.0.0.1:${KG_HOST_PORT:-4679}`, data under `${KG_DATA_DIR:-/home/node/workspace/kg-data}`), and pulls both images once. No runtime package fetch: the MCP server command runs the pre-pulled docker image, so the stack stays offline-ready.
- `kg-down.sh` removes the containers and network; the data directory is kept.
- The `falkordb` MCP entry is registered in `config/opencode.json` and joined to `kg-net`. Until `kg-up.sh` has run, the boot preflight (`boot/mcp-check.sh`) warns only - the server is optional, not baked.

Env overrides: `KG_DATA_DIR`, `KG_HOST_PORT`, `KG_DB_NAME`, `KG_NET_NAME`, `KG_DB_IMAGE`.

## Schema conventions (governance graph)

| Node | Key properties |
|---|---|
| `(:Decision {id})` | date, summary, state |
| `(:PR {number})` | title, merged_at, sha |
| `(:Finding {id})` | severity, stage, status |
| `(:File {path})` | - |
| `(:Lesson {key})` | claim, verified_by |
| `(:FailureClass {name})` | - |

| Relation | Meaning |
|---|---|
| `(Decision)-[:TOUCHES]->(File)` | files in scope of a decision |
| `(PR)-[:CLOSES]->(Finding)` | review finding dispositioned by a PR |
| `(PR)-[:MERGED_AS]->(Decision)` | PR that landed a decision |
| `(Lesson)-[:PREVENTS]->(FailureClass)` | what a lesson guards against |
| `(Decision)-[:SUPERSEDES]->(Decision)` | decision lineage |

Example queries:

```cypher
// Which lessons guard against a failure class a PR recently hit?
MATCH (l:Lesson)-[:PREVENTS]->(f:FailureClass)<-[:CAUSED]-(pr:PR)
WHERE f.name = 'compile' RETURN l.key, pr.number ORDER BY pr.merged_at DESC

// Files a decision and its superseding decision jointly touched
MATCH (d2:Decision)-[:SUPERSEDES]->(d1:Decision)-[:TOUCHES]->(f:File)
WHERE d1.id = 'orchestration-contract' RETURN d2.id, collect(f.path)
```

## Persistence

The DB writes RDB snapshots to the mounted data volume, so graph data survives container restarts and rebuilds. `kg-down.sh` never deletes the data directory; remove it by hand only when the graph is disposable.

## Notes

- This is a deliberate graph-memory integration, distinct from the official `server-memory` package (which this project does not ship).
- The graph complements, never replaces: lean-ctx `ctx_knowledge` (semantic recall), `ctx_callgraph`/`ctx_impact` (code graph), and rag (workspace retrieval). It is the entity-relation layer between them.
