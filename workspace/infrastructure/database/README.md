# infrastructure/database

Database service definitions. Two engines are wired: `mssql/` and `postgres/`. The repo-root compose file references these directories; nothing here loads on its own.

## Current state

Both engine directories are empty placeholders, each with a `.gitignore` so local data and build outputs never reach the repository.

| Directory | Engine | State |
| --- | --- | --- |
| `mssql/` | Microsoft SQL Server | Placeholder; init scripts land here |
| `postgres/` | PostgreSQL | Placeholder; init scripts land here |

## Conventions for populating

- Keep engine-specific files inside the engine's own directory: init SQL, healthcheck helpers, image tweaks.
- Mount persistent data on a compose volume, never into this tree. This directory holds definitions, not data.
- Every database service in the compose file carries a healthcheck; keep that pattern when you add one, so the OpenCode stack's MCP readiness preflight can depend on it.
- Credentials flow from the host `.env` through compose variable substitution. Do not bake them into scripts here.
