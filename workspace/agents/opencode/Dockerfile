FROM node:22-bookworm-slim

# Version ARGs: empty value (the default) = latest; set via compose args to pin.
# The offline store is the real lockfile - every store tier below is glob-based
# (<pkg>-*.tgz / <pkg>-*.whl) - so these numbers only matter for the network
# fallbacks, which use @latest / no version spec while the ARG is empty.
ARG OPENCODE_VERSION=""
# Platform package suffix used by the offline store tarball glob
# (opencode-cli-linux-<arch>-<version>.tgz - npm pack flattens the scope).
# npm platform names: x64 / arm64. The value is DERIVED from TARGETARCH in the
# install RUN below, because the tarball must match the image platform - a
# hardcoded arm64 tarball on an x64 host fails with npm EBADPLATFORM. This ARG
# is an explicit override for that derivation; empty = follow the platform.
ARG OPENCODE_ARCH=""
# Build platform (docker buildx/compose always provides it; amd64 | arm64).
# Also used by the docker-CLI download block below.
ARG TARGETARCH
ARG LEAN_CTX_VERSION=""
ARG CONTEXT7_VERSION=""
ARG MCP_VERSION=""
ARG MCP_SERVER_FETCH_VERSION=""
# Structural AST search CLI (binary: ast-grep). Release zips ship an `sg`
# compat shim next to the real binary; only the `ast-grep` member is baked,
# never the shim (coreutils owns /usr/bin/sg).
ARG AST_GREP_VERSION=""
# Vendored first-party plugin (@firecrawl/opencode) + its runtime dep
ARG ZOD_VERSION=""
ARG FIRECRAWL_CLI_VERSION=""

# Corporate CA certificates.
# Place PEM certificates with the .crt extension under certs/.
COPY certs/ /usr/local/share/ca-certificates/

# Base packages - OFFLINE-FIRST from the store, like every other tier below.
# pre-install/packages-apt.txt (git-tracked) is the single source of truth
# for the package set: populate-preinstall.sh resolves its full transitive
# .deb closure into store/apt/ (Debian 12 bookworm, the populating host's
# dpkg arch - pinned in versions.lock) and writes a deps-first
# install-order.txt. apt-install.sh then installs from the store with one
# dpkg transaction when the store is present, complete, and arch-matching:
# no apt-get update, no network, no apt-get upgrade. A missing, partial, or
# wrong-arch store falls back to the network tier with a loud log line, so
# builds never silently change behavior. TOFU window: first-fetch debs are
# unverified until the maintainer --update-digests run records pins (same
# caveat as every other store tier). Still outside store scope: the FROM
# base image pull itself.
COPY apt-install.sh /tmp/apt-install/apt-install.sh
COPY pre-install/packages-apt.txt /tmp/apt-install/packages-apt.txt
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=from=preinstall,src=/,dst=/pi,ro \
    set -eux; \
    sh /tmp/apt-install/apt-install.sh /tmp/apt-install/packages-apt.txt /pi/apt; \
    rm -rf /tmp/apt-install

# --- Offline-store digest gate (S3/P2-9) ------------------------------------
# Enforces ONLY when pre-install/digests.sha256 carries pins (>0 non-comment
# entries): a fresh checkout ships a comment-only manifest, and this gate
# logs loudly and skips so pre-population builds stay green. After the
# maintainer's one-time --update-digests run, every build re-hashes the
# mounted store and fails on any mismatch (tampered file quarantined) or
# store file with no pin. TOFU caveat: pins are only as trustworthy as the
# connection the maintainer first recorded them on (see the populate script
# header). A digest-pin update invalidates all later layers by design.
COPY populate-preinstall.sh /tmp/digest-gate/populate-preinstall.sh
COPY pre-install/digests.sha256 /tmp/digest-gate/pre-install/digests.sha256
RUN --mount=from=preinstall,src=/,dst=/pi,ro \
    set -eu; \
    pins=$(grep -cvE '^[[:space:]]*(#|$)' /tmp/digest-gate/pre-install/digests.sha256 2>/dev/null || true); \
    if [ -z "$pins" ]; then pins=0; fi; \
    if [ "$pins" -gt 0 ]; then \
      echo "digest gate: $pins pin(s) in pre-install/digests.sha256 - ENFORCING (populate-preinstall.sh --verify-digests)"; \
      PREINSTALL_STORE=/pi sh /tmp/digest-gate/populate-preinstall.sh --verify-digests; \
    else \
      echo "digest gate: 0 pins (comment-only manifest) - pre-population build, verification SKIPPED; run --update-digests once with network access to enable enforcement"; \
    fi; \
    rm -rf /tmp/digest-gate

# Configure Node.js and Python to trust the corporate CA.
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    PIP_CERT=/etc/ssl/certs/ca-certificates.crt

# Locale + terminal defaults so the TUI and ncurses apps render correctly in
# `docker exec -it` sessions (which inherit the container env, not the host's).
ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color

# Install OpenCode and the Context7 MCP server.
# Context7 is baked (not npx) so library docs lookup works on
# offline / CA-restricted corporate networks without a runtime download.
# Tarball-first from the offline store (/pi/npm), network as fallback.
#
# Store filenames are what `npm pack <scoped-pkg>` actually writes: the scope
# is flattened to a plain prefix, with no @ or + and no nested directory
# (`npm pack @opencode/cli` -> opencode-cli-<v>.tgz). populate-preinstall.sh
# prunes older versions on each bump, so these globs stay single-match - which
# is what makes `npm install -g /pi/npm/opencode-cli-*.tgz` safe.
#
# The CLI glob must start with a digit: `opencode-cli-*.tgz` would ALSO match
# the platform tarball `opencode-cli-linux-<arch>-<v>.tgz`, so the CLI and
# platform globs would overlap and the platform tarball would be installed
# twice. `opencode-cli-[0-9]*.tgz` matches version tarballs only.
#
# Arch follows the build platform (TARGETARCH): docker builds arm64 => arm64,
# amd64 => x64. OPENCODE_ARCH build arg overrides. Installing the other
# platform's tarball fails at npm install with EBADPLATFORM.
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    --mount=from=preinstall,src=/,dst=/pi,ro \
    set -eux; \
    case "${TARGETARCH}" in \
      amd64) OC_ARCH=x64 ;; \
      arm64) OC_ARCH=arm64 ;; \
      *) OC_ARCH=x64 ;; \
    esac; \
    if [ -n "${OPENCODE_ARCH}" ]; then OC_ARCH="${OPENCODE_ARCH}"; fi; \
    echo "opencode platform arch: ${OC_ARCH} (TARGETARCH=${TARGETARCH:-unknown})"; \
    if ls /pi/npm/opencode-cli-[0-9]*.tgz >/dev/null 2>&1 \
       && ls /pi/npm/opencode-cli-linux-${OC_ARCH}-*.tgz >/dev/null 2>&1; then \
      npm install -g --offline --no-audit --no-fund \
        /pi/npm/opencode-cli-[0-9]*.tgz /pi/npm/opencode-cli-linux-${OC_ARCH}-*.tgz \
        || npm install -g --no-audit --no-fund \
        /pi/npm/opencode-cli-[0-9]*.tgz /pi/npm/opencode-cli-linux-${OC_ARCH}-*.tgz; \
    else \
      if [ -n "${OPENCODE_VERSION}" ]; then OCK="@${OPENCODE_VERSION}"; else OCK="@latest"; fi; \
      echo "network fallback: @opencode/cli${OCK} (ARG empty = latest)"; \
      npm install -g --no-audit --no-fund "@opencode/cli${OCK}"; \
    fi; \
    if ls /pi/npm/upstash-context7-mcp-*.tgz >/dev/null 2>&1; then \
      npm install -g --offline --no-audit --no-fund /pi/npm/upstash-context7-mcp-*.tgz \
        || npm install -g --no-audit --no-fund /pi/npm/upstash-context7-mcp-*.tgz; \
    else \
      if [ -n "${CONTEXT7_VERSION}" ]; then C7K="@${CONTEXT7_VERSION}"; else C7K="@latest"; fi; \
      npm install -g --no-audit --no-fund "@upstash/context7-mcp${C7K}"; \
    fi; \
    opencode --version; \
    command -v context7-mcp

# lean-ctx binary: from the offline store when present, else upstream installer.
RUN --mount=from=preinstall,src=/,dst=/pi,ro \
    set -eux; \
    store_ok=false; \
    if [ -f /pi/bin/lean-ctx ]; then \
      install -m 0755 /pi/bin/lean-ctx /usr/local/bin/lean-ctx; \
      lean-ctx --version >/dev/null 2>&1 && store_ok=true || rm -f /usr/local/bin/lean-ctx; \
    fi; \
    if [ "$store_ok" != true ]; then \
      echo "store lean-ctx missing or wrong-arch — fetching from network"; \
      if [ -n "${LEAN_CTX_VERSION}" ]; then \
        LC_URL="https://raw.githubusercontent.com/yvgude/lean-ctx/v${LEAN_CTX_VERSION}/install.sh"; \
      else \
        LC_URL="https://raw.githubusercontent.com/yvgude/lean-ctx/main/install.sh"; \
      fi; \
      echo "lean-ctx installer: ${LC_URL} (ARG empty = default branch)"; \
      curl -fsSL "${LC_URL}" -o /tmp/leanctx-install.sh; \
      chmod +x /tmp/leanctx-install.sh; \
      LEAN_CTX_NO_ONBOARD=1 sh /tmp/leanctx-install.sh --download; \
      install -m 0755 /root/.local/bin/lean-ctx /usr/local/bin/lean-ctx; \
      rm -rf /root/.local /tmp/leanctx-install.sh; \
    fi; \
    lean-ctx --version

# Docker CLI (client only - talks to the host daemon via the compose socket mount).
# TARGETARCH is declared in the top ARG block and used here for the download arch.
# Store-first: populate-preinstall.sh bakes the static client binary into the
# store (bin/docker) at the pinned DOCKER_CLI_VERSION; this build installs it
# without touching the network. The network tier below is the fallback for
# stores populated before this artifact existed: resolve latest at build time,
# ARG is the last-resort fallback when the GitHub API is unreachable.
ARG DOCKER_CLI_VERSION=27.3.1
RUN --mount=from=preinstall,src=/,dst=/pi,ro \
    set -eux; \
    store_ok=false; \
    if [ -f /pi/bin/docker ]; then \
      install -m 0755 /pi/bin/docker /usr/local/bin/docker; \
      docker --version >/dev/null 2>&1 && store_ok=true || rm -f /usr/local/bin/docker; \
    fi; \
    if [ "$store_ok" != true ]; then \
      echo "store docker CLI missing or wrong-arch - fetching from network"; \
      DC_LATEST=$(curl -fsSL https://api.github.com/repos/docker/cli/releases/latest 2>/dev/null \
        | sed -n 's/.*"tag_name": "v\([^"]*\)".*/\1/p' | head -1); \
      DOCKER_CLI_VERSION="${DC_LATEST:-$DOCKER_CLI_VERSION}"; \
      echo "docker CLI: ${DOCKER_CLI_VERSION}"; \
      case "${TARGETARCH}" in \
        arm64) DC_ARCH=aarch64 ;; \
        amd64) DC_ARCH=x86_64 ;; \
        *) DC_ARCH=x86_64 ;; \
      esac; \
      curl -fsSL "https://download.docker.com/linux/static/stable/${DC_ARCH}/docker-${DOCKER_CLI_VERSION}.tgz" -o /tmp/docker-cli.tgz; \
      tar -xzf /tmp/docker-cli.tgz -C /tmp; \
      install -m 0755 /tmp/docker/docker /usr/local/bin/docker; \
      rm -rf /tmp/docker /tmp/docker-cli.tgz; \
    fi; \
    docker --version

# Install the fetch MCP server (wheel-first from the offline store).
ENV PIPX_HOME=/opt/pipx \
    PIPX_BIN_DIR=/usr/local/bin

RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    --mount=from=preinstall,src=/,dst=/pi,ro \
    set -eux; \
    if ls /pi/pip/mcp_server_fetch-*.whl >/dev/null 2>&1; then \
      PIP_FIND_LINKS=/pi/pip PIP_NO_INDEX=true pipx install /pi/pip/mcp_server_fetch-*.whl; \
    else \
      if [ -n "${MCP_SERVER_FETCH_VERSION}" ]; then MSF="==${MCP_SERVER_FETCH_VERSION}"; else MSF=""; fi; \
      pipx install "mcp-server-fetch${MSF}"; \
    fi; \
    # Bake readabilipy's Readability.js deps: without node_modules in the
    # package dir, the fetch server shells out to `npm install` per request,
    # which fails air-gapped. Small tree; network-at-build is acceptable
    # (same trade-off as the other network fallbacks above).
    JS_DIR="/opt/pipx/venvs/mcp-server-fetch/lib/python3.11/site-packages/readabilipy/javascript"; \
    npm install --prefix "$JS_DIR" --no-audit --no-fund; \
    test -d "$JS_DIR/node_modules/@mozilla/readability"

# ast-grep: structural AST pattern search CLI. Store-first like the other
# binaries: populate-preinstall.sh bakes bin/ast-grep (extracted from the
# release zip, which carries BOTH an `sg` compat shim and the real
# `ast-grep` binary - only the ast-grep member is installed, NEVER as `sg`:
# coreutils ships /usr/bin/sg and a collision would shadow it). The network
# tier below is the fallback: it resolves the latest release tag at build
# time; AST_GREP_VERSION pins it and doubles as the last-resort fallback when
# the GitHub API is unreachable (verified working tag, never a guess).
RUN --mount=from=preinstall,src=/,dst=/pi,ro \
    set -eux; \
    store_ok=false; \
    if [ -f /pi/bin/ast-grep ]; then \
      install -m 0755 /pi/bin/ast-grep /usr/local/bin/ast-grep; \
      ast-grep --version >/dev/null 2>&1 && store_ok=true || rm -f /usr/local/bin/ast-grep; \
    fi; \
    if [ "$store_ok" != true ]; then \
      echo "store ast-grep missing or wrong-arch - fetching from network"; \
      AG_LATEST=$(curl -fsSL https://api.github.com/repos/ast-grep/ast-grep/releases/latest 2>/dev/null \
        | sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p' | head -1); \
      if [ -n "${AG_LATEST}" ]; then \
        AST_GREP_VERSION="${AG_LATEST}"; \
      elif [ -z "${AST_GREP_VERSION}" ]; then \
        AST_GREP_VERSION="0.51.3"; \
      fi; \
      echo "ast-grep: ${AST_GREP_VERSION}"; \
      case "${TARGETARCH}" in \
        arm64) AG_TARGET=aarch64-unknown-linux-gnu ;; \
        amd64) AG_TARGET=x86_64-unknown-linux-gnu ;; \
        *) AG_TARGET=x86_64-unknown-linux-gnu ;; \
      esac; \
      curl -fsSL "https://github.com/ast-grep/ast-grep/releases/download/${AST_GREP_VERSION}/app-${AG_TARGET}.zip" -o /tmp/ast-grep.zip; \
      python3 -c 'import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extract("ast-grep", sys.argv[2])' /tmp/ast-grep.zip /tmp; \
      install -m 0755 /tmp/ast-grep /usr/local/bin/ast-grep; \
      rm -f /tmp/ast-grep /tmp/ast-grep.zip; \
    fi; \
    ast-grep --version

# Prepare OpenCode configuration and persistent-data directories.
RUN mkdir -p \
      /home/node/.config/opencode \
      /home/node/.config/lean-ctx \
      /home/node/.local/share/opencode \
      /home/node/workspace \
 && chown -R node:node /home/node

# Web uploads stage into /tmp/opencode/uploads — must be writable by the node
# user (root runtime processes can otherwise create it root-owned first).
RUN mkdir -p /tmp/opencode && chown node:node /tmp/opencode

# lean-ctx config bake: shell_allowlist_extra merges onto the built-in read-only
# allowlist so agent sessions can run docker/sh/bash/sudo/ss through ctx_shell
# without refusals. Baked at build time because lean-ctx blocks agents from
# changing their own policy at runtime. Runtime extensions: `lean-ctx allow <cmd>`;
# escape hatches and the opencode/ccc examples are commented in the shipped file.
COPY --chown=node:node config/lean-ctx-config.toml /home/node/.config/lean-ctx/config.toml

# Install the entrypoint and normalize Windows CRLF line endings.
# (Placed before COPY engine/ so engine edits don't invalidate these layers.)
COPY entrypoint.sh /usr/local/bin/opencode-entrypoint.sh

RUN sed -i 's/\r$//' /usr/local/bin/opencode-entrypoint.sh \
 && chmod 755 /usr/local/bin/opencode-entrypoint.sh

USER node

# NOTE: the removed custom plugins (model-fallback, dcp, websearch-cited)
# targeted the V1 plugin API and V2 also refuses the old file://<file>
# plugin entries ("configured plugin path must be a directory"), so they
# silently never loaded. Remove this note once they are ported to the V2
# @opencode/plugin API and re-added to config/opencode.json. The first-party
# @firecrawl/opencode plugin is separate: it is V2-native and vendored
# offline at engine/plugins/opencode-firecrawl (see the RUN block below).

# Copy the shared workflow engine. (Kept LAST: engine edits only invalidate
# the layers below, not the package installs above.)
ENV ENGINE_ROOT=/opt/engine

# Engine transform needs root: removes root-owned files, chowns, sets exec bits
USER root

COPY engine/ /opt/engine/

# Bake the skills manifest (engine/skills.json): boot checks compare its count
# against the shipped skill directories without scanning at runtime.
RUN bash /opt/engine/scripts/gen-skills-manifest.sh /opt/engine/skills.json \
 && jq -e '.count > 0' /opt/engine/skills.json >/dev/null

# RAG MCP server: zero-dependency node script (rag/server.js -> /opt/rag).
# Image-baked as the base; compose additionally bind-mounts ./rag:/opt/rag:ro
# so server edits activate without a rebuild (the mount wins when present).
COPY rag/ /opt/rag/

# Vendored @firecrawl/opencode plugin: install its single runtime dependency
# (zod) from the offline store into the plugin dir, and firecrawl-cli
# (binary: firecrawl) globally. Tarball-first from /pi/npm, network fallback,
# same style as the npm blocks above. Runs before the engine transform below
# so the final chown covers the installed node_modules.
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    --mount=from=preinstall,src=/,dst=/pi,ro \
    set -eux; \
    rm -rf /tmp/zod-install; \
    mkdir -p /tmp/zod-install; \
    if ls /pi/npm/zod-*.tgz >/dev/null 2>&1; then \
      npm install --no-save --no-package-lock --offline --no-audit --no-fund \
        --prefix /tmp/zod-install /pi/npm/zod-*.tgz \
        || npm install --no-save --no-package-lock --no-audit --no-fund \
        --prefix /tmp/zod-install /pi/npm/zod-*.tgz; \
    else \
      npm install --no-save --no-package-lock --no-audit --no-fund \
        --prefix /tmp/zod-install "zod@${ZOD_VERSION:-latest}"; \
    fi; \
    rm -rf /opt/engine/plugins/opencode-firecrawl/node_modules; \
    mv /tmp/zod-install/node_modules /opt/engine/plugins/opencode-firecrawl/node_modules; \
    rm -rf /tmp/zod-install; \
    if ls /pi/npm/firecrawl-cli-*.tgz >/dev/null 2>&1; then \
      npm install -g --offline --no-audit --no-fund /pi/npm/firecrawl-cli-*.tgz \
        || npm install -g --no-audit --no-fund /pi/npm/firecrawl-cli-*.tgz; \
    else \
      npm install -g --no-audit --no-fund "firecrawl-cli@${FIRECRAWL_CLI_VERSION:-latest}"; \
    fi; \
    test -d /opt/engine/plugins/opencode-firecrawl; \
    test -d /opt/engine/plugins/opencode-firecrawl/node_modules/zod; \
    test ! -d /opt/engine/plugins/opencode-firecrawl/node_modules/@opencode

RUN set -eux; \
    rm -f /opt/engine/.env /opt/engine/.env.template; \
    find /opt/engine -type f \( \
        -name '*.sh' \
        -o -name '*.md' \
        -o -name '*.json' \
        -o -name '*.js' \
        -o -name '*.mjs' \
        -o -name '*.ts' \
        -o -name '*.py' \
      \) -exec sed -i 's/\r$//' {} +; \
    if [ -d /opt/engine/.githooks ]; then \
      find /opt/engine/.githooks \
        -type f \
        -exec sed -i 's/\r$//' {} + \
        -exec chmod a+x {} +; \
    fi; \
    find /opt/engine -name '*.md' -not -path '/opt/engine/plugins/*' \
      -exec sed -E -i \
        -e 's#\.opencode/(agents|skills|rules|usage|contract)/#/opt/engine/\1/#g' \
        {} +; \
    python3 /opt/engine/scripts/normalize-doc-paths.py /opt/engine /opt/engine; \
    find /opt/engine -name '*.sh' -exec chmod a+x {} +; \
    chown -R node:node /opt/engine; \
    ln -sfn /opt/engine/agent.md \
      /home/node/.config/opencode/agent.md; \
    ln -sfn /opt/engine/agents \
      /home/node/.config/opencode/agents; \
    ln -sfn /opt/engine/skills \
      /home/node/.config/opencode/skills; \
    ln -sfn /opt/engine/commands \
      /home/node/.config/opencode/commands; \
    ln -sfn /opt/engine/rules \
      /home/node/.config/opencode/rules; \
    ln -sfn /opt/engine/contract \
      /home/node/.config/opencode/contract; \
    ln -sfn /opt/engine/usage \
      /home/node/.config/opencode/usage; \
    ln -sfn /opt/engine/doc \
      /home/node/.config/opencode/doc

# Drop back to the runtime user; nothing below needs root.
USER node

WORKDIR /home/node/workspace

ENTRYPOINT ["/usr/local/bin/opencode-entrypoint.sh"]

# entrypoint.sh probes and prefers `opencode serve`; CMD kept in sync with
# that path and serves as the bare fallback.
CMD ["opencode", "serve", "--hostname", "0.0.0.0", "--port", "4096"]
