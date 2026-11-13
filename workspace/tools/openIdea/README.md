# OpenIDEA in Docker

[OpenIDEA](https://github.com/l0ng-ai/openidea) (IntelliJ-style IDE, Rust + Tauri)
packaged as a container. The image builds from the newest GitHub release unless
you pin a version.

Two display modes, one image, chosen at runtime with `MODE`:

| MODE | How you see it |
|------|----------------|
| `web` (default) | Xvfb + openbox + x11vnc + noVNC. Open `http://127.0.0.1:4190/vnc.html` |
| `x11` | Uses a mounted host X11 / WSLg socket and `DISPLAY`. Needs no VNC stack |

## Build

```sh
docker compose -f docker-compose.example.yaml build
```

Pin a release instead of tracking latest:

```sh
OPENIDEA_VERSION=0.1.44 docker compose -f docker-compose.example.yaml build
```

## Run — web

```sh
docker compose -f docker-compose.example.yaml --profile web up -d
```

Then open <http://127.0.0.1:4190/vnc.html>. The VNC port is published on
`127.0.0.1` only, because x11vnc runs without a password (`-nopw`). Do not
widen the port binding without adding `-rfbauth`.

## Run — x11 (Linux / WSLg)

```sh
docker compose -f docker-compose.example.yaml --profile x11 up
```

WSLg works as-is. On a plain Linux host, allow local clients first
(`xhost +local:`) and delete the `/mnt/wslg` volume line from the compose file.

## Environment

| Variable | Default | Meaning |
|----------|---------|---------|
| `MODE` | `web` | `web` or `x11` |
| `NOVNC_PORT` | `4190` | noVNC listen port (web mode) |
| `DISPLAY` | `:1` web, `:0` x11 | X display; in web mode the entrypoint owns `:1` |
| `XVFB_GEOMETRY` | `1440x900x24` | Virtual screen size (web mode) |
| `OPENIDEA_BIN` | `openidea` | Override the IDE binary (debugging) |

## Ports

| Port | Service |
|------|---------|
| `4190` | noVNC web UI (web mode) |
| `5900` | x11vnc, loopback inside the container only |

## Volumes

| Host path | Container path | Purpose |
|-----------|----------------|---------|
| `./project` | `/home/ide/project` | Your code |
| named `openidea-config` | `/home/ide/.config/OpenIDEA` | IDE settings, survives rebuilds |
| `/var/run/docker.sock` | `/var/run/docker.sock` | Docker dashboards inside the IDE |

The runtime user is `ide` (uid/gid 1000). If `./project` ends up root-owned
after the container writes to it, run `sudo chown -R 1000:1000 project`.

## Corporate CA certificates

Behind a TLS-inspecting proxy (Zscaler and friends) the build cannot reach
GitHub until the proxy root CA is trusted. Drop the PEM files into `certs/`
with a `.crt` extension before building:

```sh
cp /path/to/zscaler-root.crt certs/
```

The Dockerfile installs everything in `certs/` into the system trust store
before the first network request. `certs/*.crt` is gitignored; only `.gitkeep`
is tracked, and an empty directory changes nothing.

## What the build does

1. Installs the GTK3/WebKitGTK runtime and the VNC stack from Debian bookworm.
2. Requests a release tagged `v<version>` from the GitHub API. Empty
   `OPENIDEA_VERSION` means "newest" — the tag is read from
   `releases/latest` at build time.
3. Downloads `OpenIDEA_<version>_<amd64|arm64>.deb` and installs it with apt,
   which resolves the package's declared dependencies.
4. Installs the static Docker CLI (client only — it talks to the mounted host
   socket; there is no daemon in this image).

Architecture follows the build platform: `amd64` → `amd64` asset, `arm64` →
`arm64` asset. Build with `--platform linux/arm64` on an arm64 host and the
matching build is fetched automatically.