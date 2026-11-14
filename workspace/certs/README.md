# certs/ - single source for corporate CA certs

All TLS interception certs (Zscaler MITM and manual roots) live HERE and only
here. The submodule cert dirs (`agents/opencode/certs`,
`agents/openui/app/certs`) are mirrors, not sources: they are refreshed by
`sync-certs.sh` and must never be edited directly.

## Flow

    sh certs/sync-certs.sh     # seed (if empty) + mirror to all submodules

- `sync-certs.sh` runs `detect-zscaler.sh` on this dir when no `*.crt` exists
  yet (auto-seed), then mirrors the exact parent set into every submodule
  cert dir.
- Run it before `docker build` - the Dockerfiles `COPY certs/` from the
  submodule dirs.
- `agents/opencode/populate-preinstall.sh` runs the detector + sync on every
  populate, so certs refresh whenever the offline store is updated.

## Manual vs autodetected

- `zscaler-autodetected-*.crt` - output of `detect-zscaler.sh`; deleted and
  rewritten on every interception-found run. Never edit.
- Any other `*.crt` - manual certs (e.g. exported corporate roots); never
  touched by the detector or the sync.

## Rotation

Corporate MITM roots rotate. Re-run the detector (or `sync-certs.sh`, or
`populate-preinstall.sh`): the autodetected set is re-derived from the live
wire and re-mirrored. Manual certs survive untouched.

## Git policy

Cert CONTENT here is gitignored by design - corporate certs are never
committed. The two scripts (`detect-zscaler.sh`, `sync-certs.sh`) and this
README ARE tracked (see the `.gitignore` negations).
