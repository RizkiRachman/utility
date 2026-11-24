# Kestra Provisioning

![kestra](https://img.shields.io/badge/kestra-1.3.26-blue)
![edition](https://img.shields.io/badge/edition-OSS-green)
![method](https://img.shields.io/badge/flows-as%20code-orange)

Flows as code for the `platform` namespace. This folder is the source of truth:
the kestra image build copies it in, and the server loads every flow at startup.
No manual imports after a fresh install.

<!-- TOC -->
- [Flows](#flows)
- [Quick start](#quick-start)
- [Auto-provisioning](#auto-provisioning)
- [Secrets wiring](#secrets-wiring)
- [Vault payload contract](#vault-payload-contract)
- [Local behavior notes](#local-behavior-notes)
- [Troubleshooting](#troubleshooting)
<!-- /TOC -->

## Flows

| Flow | What it does | Inputs |
|---|---|---|
| `platform-deployer` | Plans, applies or destroys a web-deployer platform. State reconciliation lands in the namespace KV store. | `repository_url` (STRING, required, no default) - `repository_name` (STRING, required, no default) - `action` (SELECT: plan / apply / destroy, default plan) |
| `platform-secrets` | Reads the Gitea token from Vault, verifies it against the Gitea API, records the identity in the namespace KV store. | none |

## Quick start

Open the UI at `http://127.0.0.1:4800`, go to Flows, namespace `platform`, pick a
flow and hit Execute. The API works the same way:

```bash
# run platform-deployer (v1.3 takes inputs as multipart/form-data)
curl -u "$USER:$PASS" -X POST \
  -F "repository_url=http://localhost:3300/development-tools/springboot-application-web-deployer" \
  -F "repository_name=Spring Boot Application Web Deployer" \
  -F "action=plan" \
  http://127.0.0.1:4800/api/v1/main/executions/platform/platform-deployer

# run platform-secrets (no inputs)
curl -u "$USER:$PASS" -X POST \
  http://127.0.0.1:4800/api/v1/main/executions/platform/platform-secrets
```

`main` is the fixed OSS tenant id. An invalid `action` value is rejected: the
input is a SELECT with `allowCustomValue: false`.

## Auto-provisioning

Flows live in the database, not in the image, so the build cannot "install"
them. The Dockerfile does the next best thing:

1. `COPY provisioning/ /app/provisioning/` bakes the YAML into the image.
2. The build renames each file to `main_platform_<flow>.yml`. Kestra derives
   tenant and namespace from the filename; files without the prefix are
   rejected with a tenantId validation error.
3. The compose config enables the local flow sync:

```yaml
micronaut:
  io:
    watch:
      enabled: true
      paths:
        - /app/provisioning
```

At every startup the watcher loads the directory into the database. A fresh
instance therefore boots with both flows already deployed. Verified on an
empty database: both flows present at revision 1, zero manual steps.

## Secrets wiring

Kestra OSS has no secret store. The `secret()` function reads base64-encoded
`SECRET_*` environment variables, and Vault-as-backend is an Enterprise
feature. The wiring used here:

- The **Vault token** reaches kestra as `SECRET_VAULT_TOKEN` (base64) in the
  environment. Flows read it with `{{ secret('VAULT_TOKEN') }}`.
- The **Gitea token** lives only in Vault. Flows fetch it per-run over the
  Vault HTTP API, use it, and never persist it. Recreating the container or
  dumping the database exposes no Gitea token.

The kestra service joins the external `bpgv5-network` (where `vault` and
`gitea` run) and gets `VAULT_ADDR=http://vault:8200`. Without that network
attachment the service names do not resolve.

Local `.env` additions (gitignored):

```text
SECRET_VAULT_TOKEN_B64=<base64 of the vault token>
```

Generate with `base64 -w0 vault-token > vault-token.b64`.

## Vault payload contract

Path `general/cicd/kestra` (KV v2):

| Key | Value |
|---|---|
| `gitea_url` | `http://gitea:3300` (docker network service name; Gitea listens on 3300 internally, not 3000) |
| `gitea_token` | Gitea API token issued for kestra |
| `issued_for` | `kestra-platform` |
| `gitea_token_id` | Token id in Gitea, for revocation tracking |

Note: the token in this deployment can write `general`, `application` and
`component` mounts but not `bpg`, despite carrying the `admin` policy. New
secrets for kestra go under `general/`.

## Local behavior notes

- `platform-deployer` inputs are mandatory by design: every run states which
  repository it targets. If you need a zero-click demo flow, put it in a
  separate namespace, not here.
- The watcher syncs both ways. A flow edited in the UI is written back to
  `/app/provisioning` inside the container, and those edits are lost when the
  container is recreated. This folder stays the source of truth: change YAML,
  merge, rebuild.
- Flows that fail validation are skipped silently by the watcher. Repo CI runs
  `validate` and `actionlint`, which catches most of it before merge.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| Flow missing after boot, log shows `tenantId: must match ...` | Filename lacks the `main_platform_` prefix. The Dockerfile rename handles this; if you drop files in manually, name them yourself. |
| `secret('VAULT_TOKEN')` fails | `SECRET_VAULT_TOKEN_B64` missing from `.env` or the container predates it. Recreate with `docker compose up -d kestra`. |
| Vault or Gitea unreachable (HTTP 000) | Container is not on `bpgv5-network`. Check `docker inspect kestra` networks. |
| TLS errors on outbound HTTPS | Zscaler chain incomplete. Drop the full chain into `cicd/kestra/certs/` and rebuild; the Dockerfile imports it for apt and the JVM. |
