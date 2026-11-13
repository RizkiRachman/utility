FROM node:22-bookworm-slim

ARG OPENCODE_VERSION=2.2.5
# Platform package suffix used by the offline store tarball glob
# (@opencode+cli-linux-<arch>-<version>.tgz). Override for x64 builds:
# OPENCODE_ARCH=x64 (or x64-baseline depending on store contents).
ARG OPENCODE_ARCH=arm64
ARG LEAN_CTX_VERSION=3.12.0
ARG CONTEXT7_VERSION=4.4.4
ARG MCP_VERSION=2.3.0
ARG MCP_SERVER_FETCH_VERSION=2026.10.28
# AST-aware semantic code index (binary: ccc); [full] extra bundles local
# sentence-transformers embeddings so no embedding API key is needed.
ARG COCOINDEX_CODE_VERSION=0.2.43
# Vendored first-party plugin (@firecrawl/opencode) + its runtime dep
ARG ZOD_VERSION=4.1.8
ARG FIRECRAWL_CLI_VERSION=1.26.24

# Corporate CA certificates.
# Place PEM certificates with the .crt extension under certs/.
COPY certs/ /usr/local/share/ca-certificates/

# Base packages. The optional `preinstall` additional build context (/pi, see
# docker-compose files) pre-seeds cached .deb files so repeat builds skip most
# downloads; the apt cache mounts keep downloaded state out of the image layer.
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    --mount=type=cache,target=/var/lib/apt,sharing=locked \
    --mount=from=preinstall,src=/,dst=/pi,ro \
    set -eux; \
    cp /pi/apt/*.deb /var/cache/apt/archives/ 2>/dev/null || true; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      git \
      curl \
      sudo \
      iproute2 \
      jq \
      ripgrep \
      ca-certificates \
      python3 \
      pipx \
      python3-venv \
      coreutils \
      procps; \
    update-ca-certificates; \
    git config --system --add safe.directory '*'

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
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    --mount=from=preinstall,src=/,dst=/pi,ro \
    set -eux; \
    if ls /pi/npm/@opencode+cli-*.tgz >/dev/null 2>&1 \
       && ls /pi/npm/@opencode+cli-linux-${OPENCODE_ARCH}-*.tgz >/dev/null 2>&1; then \
      npm install -g --offline --no-audit --no-fund \
        /pi/npm/@opencode+cli-*.tgz /pi/npm/@opencode+cli-linux-${OPENCODE_ARCH}-*.tgz \
        || npm install -g --no-audit --no-fund \
        /pi/npm/@opencode+cli-*.tgz /pi/npm/@opencode+cli-linux-${OPENCODE_ARCH}-*.tgz; \
    else \
      npm install -g --no-audit --no-fund "@opencode/cli@${OPENCODE_VERSION}"; \
    fi; \
    if ls /pi/npm/@upstash+context7-mcp-*.tgz >/dev/null 2>&1; then \
      npm install -g --offline --no-audit --no-fund /pi/npm/@upstash+context7-mcp-*.tgz \
        || npm install -g --no-audit --no-fund /pi/npm/@upstash+context7-mcp-*.tgz; \
    else \
      npm install -g --no-audit --no-fund "@upstash/context7-mcp@${CONTEXT7_VERSION}"; \
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
      curl -fsSL \
        "https://raw.githubusercontent.com/yvgude/lean-ctx/v${LEAN_CTX_VERSION}/install.sh" \
        -o /tmp/leanctx-install.sh; \
      chmod +x /tmp/leanctx-install.sh; \
      LEAN_CTX_NO_ONBOARD=1 sh /tmp/leanctx-install.sh --download; \
      install -m 0755 /root/.local/bin/lean-ctx /usr/local/bin/lean-ctx; \
      rm -rf /root/.local /tmp/leanctx-install.sh; \
    fi; \
    lean-ctx --version

# Docker CLI (client only - talks to the host daemon via the compose socket mount).
ARG TARGETARCH
ARG DOCKER_CLI_VERSION=27.3.1
RUN case "${TARGETARCH}" in \
      arm64) DC_ARCH=aarch64 ;; \
      amd64) DC_ARCH=x86_64 ;; \
      *) DC_ARCH=x86_64 ;; \
    esac \
 && curl -fsSL "https://download.docker.com/linux/static/stable/${DC_ARCH}/docker-${DOCKER_CLI_VERSION}.tgz" -o /tmp/docker-cli.tgz \
 && tar -xzf /tmp/docker-cli.tgz -C /tmp \
 && install -m 0755 /tmp/docker/docker /usr/local/bin/docker \
 && rm -rf /tmp/docker /tmp/docker-cli.tgz

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
      pipx install "mcp-server-fetch==${MCP_SERVER_FETCH_VERSION}"; \
    fi; \
    # Bake readabilipy's Readability.js deps: without node_modules in the
    # package dir, the fetch server shells out to `npm install` per request,
    # which fails air-gapped. Small tree; network-at-build is acceptable
    # (same trade-off as the other network fallbacks above).
    JS_DIR="/opt/pipx/venvs/mcp-server-fetch/lib/python3.11/site-packages/readabilipy/javascript"; \
    npm install --prefix "$JS_DIR" --no-audit --no-fund; \
    test -d "$JS_DIR/node_modules/@mozilla/readability"

# Install CocoIndex Code (pipx; wheel-first from the offline store).
# Baked offline-first like the npm/pipx blocks above: the `ccc` binary IS the
# MCP server, so nothing extra needs to be baked into the image. The [full]
# extra pulls torch + transformers for local sentence-transformers embeddings,
# which makes this layer heavy — accepted deliberately over requiring a cloud
# embedding API key at runtime, matching the offline-first house style.
# The embedding model itself downloads from HuggingFace on the FIRST runtime
# index (see supports/cocoindex/README.md), so build stays network-light.
# The store wheel carries no [full] extras, so the embedding deps are injected
# with a three-tier fallback: store wheels -> network -> warn-only. Only a
# truly air-gapped build ends in the WARN; ccc still works as a CLI there but
# without local embeddings.
# The network tier resolves embeddings to CPU-only torch (~200 MB) via the
# download.pytorch.org/whl/cpu extra index, NOT the PyPI CUDA closure
# (~2-3 GB of nvidia-* wheels). The CPU wheel carries a +cpu local version,
# which sorts higher than the plain PyPI version, so pip prefers it.
# `ccc init` bakes the global settings file: without it `ccc mcp` exits code 1
# on first connect (opencode surfaces that as a 20s initialize timeout).
RUN --mount=type=cache,target=/root/.cache/pip,sharing=locked \
    --mount=from=preinstall,src=/,dst=/pi,ro \
    set -eux; \
    if ls /pi/pip/cocoindex_code-*.whl >/dev/null 2>&1; then \
      PIP_FIND_LINKS=/pi/pip PIP_NO_INDEX=true pipx install /pi/pip/cocoindex_code-*.whl; \
      if ! PIP_FIND_LINKS=/pi/pip PIP_NO_INDEX=true pipx inject cocoindex-code torch transformers sentence-transformers; then \
        echo "store lacks usable embedding wheels for this platform - trying network" >&2; \
        if ! PIP_EXTRA_INDEX_URL=https://download.pytorch.org/whl/cpu pipx inject cocoindex-code torch transformers sentence-transformers; then \
          echo "WARN: embedding deps unavailable (store miss + no network); ccc index will need network at runtime" >&2; \
        fi; \
      fi; \
    else \
      pipx install "cocoindex-code[full]==${COCOINDEX_CODE_VERSION}"; \
    fi; \
    command -v ccc; \
    ccc --help >/dev/null; \
    HOME=/home/node ccc init && test -f /home/node/.cocoindex_code/global_settings.yml || \
      echo "WARN: ccc global settings not baked - run ccc init at runtime before starting opencode" >&2

# Prepare OpenCode configuration and persistent-data directories.
RUN mkdir -p \
      /home/node/.config/opencode \
      /home/node/.local/share/opencode \
      /home/node/workspace \
 && chown -R node:node /home/node

# Web uploads stage into /tmp/opencode/uploads — must be writable by the node
# user (root runtime processes can otherwise create it root-owned first).
RUN mkdir -p /tmp/opencode && chown node:node /tmp/opencode

# lean-ctx shell allowlist extension: merged on top of the built-in defaults
# (shell_allowlist_extra per lean-ctx docs config-keys reference) so agent sessions
# can run docker/sh/bash/sudo/ss through ctx_shell without refusals. Baked at build
# time because lean-ctx deliberately blocks agents from changing their own policy
# at runtime — the user approved this expansion explicitly.
ARG LEAN_CTX_CONFIG_DIR=/home/node/.config/lean-ctx
RUN mkdir -p ${LEAN_CTX_CONFIG_DIR} \
 && printf 'shell_allowlist_extra = ["docker", "sh", "bash", "sudo", "ss"]\n' \
      > ${LEAN_CTX_CONFIG_DIR}/config.toml \
 && chown node:node ${LEAN_CTX_CONFIG_DIR}/config.toml

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
        --prefix /tmp/zod-install "zod@${ZOD_VERSION}"; \
    fi; \
    rm -rf /opt/engine/plugins/opencode-firecrawl/node_modules; \
    mv /tmp/zod-install/node_modules /opt/engine/plugins/opencode-firecrawl/node_modules; \
    rm -rf /tmp/zod-install; \
    if ls /pi/npm/firecrawl-cli-*.tgz >/dev/null 2>&1; then \
      npm install -g --offline --no-audit --no-fund /pi/npm/firecrawl-cli-*.tgz \
        || npm install -g --no-audit --no-fund /pi/npm/firecrawl-cli-*.tgz; \
    else \
      npm install -g --no-audit --no-fund "firecrawl-cli@${FIRECRAWL_CLI_VERSION}"; \
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
