# Kestra provisioning - flows as code

Deployed to the `platform` namespace via the Kestra API (or the UI import).
Every flow here follows the same contract: inputs are explicit, secrets
come from Vault, nothing sensitive is stored in kestra itself.

## Flows

- `platform-deployer.yaml` - plan/apply/destroy a web-deployer platform.
  Repository URL and Repository Name are mandatory with no defaults.
- `platform-secrets.yaml` - reads the Gitea token from Vault
  (KV v2 `general/cicd/kestra`), verifies it against the Gitea API, and
  records the resolved identity in the namespace KV store.

## Secrets wiring (OSS edition)

Kestra OSS has no built-in secret store: `secret()` reads base64-encoded
`SECRET_*` environment variables. The Vault token is provided that way;
the Gitea token lives ONLY in Vault and is fetched per-run.

In the local (non-example) compose, the kestra service needs:

```yaml
    environment:
      SECRET_VAULT_TOKEN: ${SECRET_VAULT_TOKEN_B64}
      VAULT_ADDR: http://vault:8200
    networks:
      - default
      - platform

networks:
  platform:
    external: true
    name: bpgv5-network   # where vault and gitea live
```

And in `.env` (gitignored):

```
SECRET_VAULT_TOKEN_B64=<base64 of the vault token>
```

Generate with: `base64 -w0 vault-token > vault-token.b64`

## Vault payload contract

Path `general/cicd/kestra` (KV v2), data keys:

| key | value |
|---|---|
| `gitea_url` | `http://gitea:3300` (docker network service name) |
| `gitea_token` | Gitea API token issued for kestra (scope: all) |
| `issued_for` | `kestra-platform` |
