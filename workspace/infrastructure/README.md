# infrastructure

Docker service definitions grouped by concern. The wiring (which services start, their ports and volumes) lives in the repo-root `docker-compose.example.yaml`; each directory here holds only the files for its own concern.

| Directory | Purpose |
| --- | --- |
| `database/` | Database engines and their init scripts: `mssql/` and `postgres/`. |
| `grafana/` | Grafana dashboards, datasource provisioning, and alert rules. |
| `k6/` | k6 load-test scripts and scenarios. |
| `vault/` | Vault configuration and secret templates. |

Status: every directory here is a placeholder today. The tree is wired for compose, but no payloads have been committed yet. That is deliberate: payloads land here when the corresponding service work starts, and each directory's README describes what belongs in it.

One rule that applies across this tree: real secrets never get committed. The repo `.gitignore` blocks `*.env` files by name; runtime secrets live in the host `.env` (gitignored) or in the running Vault service.
