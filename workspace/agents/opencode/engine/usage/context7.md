<!-- omit from toc -->
# Context7 Usage Guide

[![Context7 Plugin][context7-shield]][context7-url]

> **Repository**: [github.com/upstash/context7](https://github.com/upstash/context7) — up-to-date library docs and code examples for AI agents
> **MCP**: `@upstash/context7-mcp` in opencode.json

## Tools

| Tool                          | What it does                                                |
|-------------------------------|-------------------------------------------------------------|
| `context7_resolve_library_id` | Resolves a package name to a Context7-compatible library ID |
| `context7_query_docs`         | Queries library docs with specific questions                |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## When to use

| When you need…                     | Use                                                 |
|------------------------------------|-----------------------------------------------------|
| How to use a library/framework API | `context7_query_docs({libraryId, query})`           |
| Find the correct library ID        | `context7_resolve_library_id({libraryName, query})` |

<p align="right">(<a href="#readme-top">back to top</a>)</p>

## Usage pattern

```javascript
// 1. Resolve the library

context7_resolve_library_id({libraryName: "Next.js", query: "how to do auth"})

// 2. Query docs with the resolved ID

context7_query_docs({libraryId: "/vercel/next.js", query: "middleware authentication"})

```
<p align="right">(<a href="#readme-top">back to top</a>)</p>

<!-- REFERENCE LINKS -->

[doc-shield]: https://img.shields.io/badge/DOC-文档-blue?style=for-the-badge
[doc-url]: #

[docs-shield]: https://img.shields.io/badge/DOCS-文档-blue?style=for-the-badge
[docs-url]: #

[github-shield]: https://img.shields.io/badge/GitHub-181717?style=for-the-badge&logo=github
[github-url]: #

[context7-shield]: https://img.shields.io/badge/Context7-插件-blue?style=for-the-badge
[context7-url]: #
