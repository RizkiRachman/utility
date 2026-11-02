<!-- omit from toc -->
# Graphify Usage Guide
[![Graphify Plugin][graphify-shield]][graphify-url] [![Docs][docs-shield]][docs-url]

> **Repository**: [github.com/emeraldarrow/Graphify](https://github.com/emeraldarrow/Graphify) — knowledge graph queries for code understanding
> **MCP**: local Python server (`graphify.serve`)

## Tools

| Tool                     | What it does                             |
|--------------------------|------------------------------------------|
| `graphify_query_graph`   | BFS/DFS search of the knowledge graph    |
| `graphify_get_node`      | Full details for a specific node         |
| `graphify_get_neighbors` | All direct neighbors with edge details   |
| `graphify_get_community` | All nodes in a community                 |
| `graphify_god_nodes`     | Most connected nodes (core abstractions) |
| `graphify_graph_stats`   | Node count, edge count, communities      |
| `graphify_shortest_path` | Path between two concepts                |
| `graphify_list_prs`      | Open PRs with graph impact               |
| `graphify_get_pr_impact` | Detailed PR graph impact                 |
| `graphify_triage_prs`    | Actionable PRs for review                |

## When to use

| When you need…                    | Use graphify                                    | Or use lean-ctx                        |
|-----------------------------------|-------------------------------------------------|----------------------------------------|
| Broad codebase understanding      | `graphify_query_graph({question, mode: "bfs"})` | `ctx_compose()`                     |
| Trace a specific dependency chain | `graphify_query_graph({mode: "dfs"})`           | `ctx_compose()`                   |
| Core abstractions                 | `graphify_god_nodes()`                          | `ctx_impact({summaryOnly: true})` |
| PR impact assessment              | `graphify_get_pr_impact()`                      | `ctx_delta()`            |
| Direct code references            | —                                               | Prefer lean-ctx                        |
| Quick exploration                 | `graphify_get_node()` + `get_neighbors()`       | —                                      |

> **Tip**: graphify is good for broad exploration; lean-ctx is better for precise impact analysis. Use lean-ctx for production changes.

[graphify-shield]: https://img.shields.io/badge/Graphify-Plugin-blue?style=for-the-badge
[graphify-url]: #
[docs-shield]: https://img.shields.io/badge/DOCS-文档-blue?style=for-the-badge
[docs-url]: #

