# infrastructure/vault

Vault configuration and secret templates. The directory is empty today apart from a `.gitignore`.

## What belongs here

- Vault server configuration (listener, storage backend) in the shape the compose service expects.
- Policy files (`*.hcl`) that define what each consumer may read.
- Secret templates: the shape of a secret, with placeholder values.

## Rules

- Real secret values live in the running Vault service or the host `.env` (gitignored). Templates carry placeholders only; a template that contains a live value is a leak, not a template.
- Policies are reviewed like code: they grant access, so a policy change is a security change.
