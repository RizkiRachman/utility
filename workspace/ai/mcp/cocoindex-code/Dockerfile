# ccc-mcpserver:local - the cocoindex-code MCP server as a standalone container.
# Mirrors the bake in agents/opencode/Dockerfile (pinned wheel, CPU torch) but
# lives outside the engine image so the MCP server can run - and be switched
# on - like the falkordb integration. The legacy in-image `ccc mcp` stays
# active until the config entry is switched (see README).
FROM python:3.11-slim

ARG COCOINDEX_CODE_VERSION=0.2.43

# CPU-only torch: the +cpu wheel from the pytorch extra index sorts above the
# plain PyPI version, so pip skips the ~2-3 GB CUDA closure (~200 MB instead).
# `ccc init` bakes the global settings file: without it `ccc mcp` exits code 1
# on first connect.
# Corporate TLS: drop PEM certs into certs/ before building (gitignored,
# same pattern as agents/opencode/Dockerfile). Env pins pip/urllib to the
# resulting system bundle; without the corporate CA, pip fails with
# "ssl-verification-failed" on the torch wheel.
COPY certs/ /usr/local/share/ca-certificates/
RUN update-ca-certificates 2>/dev/null || true
ENV PIP_CERT=/etc/ssl/certs/ca-certificates.crt \
    SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    PIP_EXTRA_INDEX_URL=https://download.pytorch.org/whl/cpu

# Install plain wheel first: the [full] extra resolves torch from PyPI and
# drags in the nvidia-* closure. Injecting deps separately lets pip pick the
# CPU wheel (its +cpu local version sorts above the plain PyPI version).
RUN pip install --no-cache-dir pipx \
 && PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx install "cocoindex-code==${COCOINDEX_CODE_VERSION}" \
 && PIPX_HOME=/opt/pipx PIPX_BIN_DIR=/usr/local/bin pipx inject cocoindex-code torch transformers sentence-transformers \
 && ccc --help >/dev/null \
 && HOME=/home/node ccc init \
 && test -f /home/node/.cocoindex_code/global_settings.yml

# `ccc mcp` must run with the project as the working directory; sessions set
# -w /home/node/workspace. No ENTRYPOINT: the holder service runs sleep, the
# per-session MCP command runs `... ccc-mcpserver:local ccc mcp`.
