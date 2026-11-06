---
title: Docker Setup with Rancher Desktop
parent: 4157603973
---

<!-- Sample draft generated from templates/setup-guideline.md.
     The parent is the CI/CD folder (4157603973), a known child of the boundary
     folder 4125949974. A dry-run with no cached ancestry and no CONFLUENCE_TOKEN
     fails closed on purpose: run './publish.sh init' with a token first, then
     re-run the dry-run. -->

Docker Setup with Rancher Desktop runs a local Docker engine on macOS without Docker Desktop licensing. This page walks through installation, configuration, and verification of the toolchain.

## Prerequisites

- macOS 13 Ventura or later
- Administrator access on your machine
- Homebrew installed

## Steps

1. Install Rancher Desktop:

```bash
brew install --cask rancher
```

2. Launch Rancher Desktop and accept the default container runtime.
3. Select `dockerd (moby)` as the container runtime to keep Docker CLI compatibility.
4. Configure resource limits:

| Resource | Recommended | Notes |
| --- | --- | --- |
| CPU | 4 cores | Adjust to your workload |
| Memory | 8 GB | Increase for large images |
| Disk | 64 GB | Images consume space quickly |

5. Verify the Docker context:

```bash
docker context ls
```

6. Run a smoke container:

```bash
docker run --rm hello-world
```

## Verification

- `docker version` prints client and server versions without errors.
- `docker context show` returns `rancher-desktop`.
- `docker run --rm hello-world` completes with the expected welcome output.

## Troubleshooting

| Symptom | Cause | Fix |
| --- | --- | --- |
| Docker socket missing | Rancher Desktop not fully started | Restart Rancher Desktop and check `~/.rd/docker.sock` |
| Image pull failures | Network blocks the registry | Confirm registry access with your network team |

## Ownership

Owned by development-tools.
