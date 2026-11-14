# pre-installer/ - offline package store

Offline mirror that feeds the docker builds so images build without network:
apt `.deb` pools, npm tarballs, pip wheels, git repo mirrors (`git/`),
standalone binaries (`bin/`), and platform dist tarballs (`dist/`). This
folder is the single source shared by all submodules;
`agents/opencode/pre-install/` keeps only the git-tracked `versions.lock` and
a `.gitkeep` placeholder.

## Who consumes it

- `agents/opencode/Dockerfile`: every offline tier mounts the store via
  `--mount=from=preinstall` (build additional context `preinstall`).
- `agents/opencode/docker-compose.example.yaml`:
  `build.additional_contexts.preinstall` points at `../../pre-installer`
  (this folder).

## How to populate

    sh agents/opencode/populate-preinstall.sh

Needs network. Idempotent and version-aware: same-version artifacts are
skipped, changed versions are re-fetched and stale copies pruned; the run's
resolved versions are written to
`agents/opencode/pre-install/versions.lock`. The cert refresh (detector +
`certs/sync-certs.sh`) runs before the downloads so corporate MITM proxies
are trusted. The store location can be overridden with `PREINSTALL_STORE`.

## Portability

The store is never committed (gitignored by design) - it lives only on local
disk / inside the workspace volume. To move it, copy the workspace; to start
fresh, delete sections and re-run the populate script.
