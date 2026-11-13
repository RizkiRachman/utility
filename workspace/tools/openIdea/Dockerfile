# OpenIDEA container image.
#
# Two display modes from one image, chosen at runtime by MODE:
#   MODE=web  (default) Xvfb -> openbox -> x11vnc -> noVNC/websockify on $NOVNC_PORT
#   MODE=x11            Needs a mounted host X11/WSLg socket and DISPLAY
#
# Trimmed from the house Debian base: GUI runtime + VNC stack + the IDE.
FROM debian:bookworm-slim

# Build platform (docker buildx/compose provide it: amd64 | arm64).
# Empty default keeps `set -u` safe on the legacy builder, which does not
# populate TARGETARCH; the case arms below fall back to amd64 in that case.
ARG TARGETARCH=""

# Empty (default) = resolve the newest GitHub release at build time.
# Set to a version like 0.1.44 to pin.
ARG OPENIDEA_VERSION=""

# Docker CLI (client only - reaches the host daemon via the compose socket
# mount). Pinned fallback used when the GitHub API is unreachable.
ARG DOCKER_CLI_VERSION=27.3.1

# Corporate CA certificates. Drop PEM files named *.crt into certs/; the
# directory ships with only .gitkeep, so this is a no-op without certs.
COPY certs/ /usr/local/share/ca-certificates/

ENV DEBIAN_FRONTEND=noninteractive

# 1) Trust the corporate CA before any network fetch happens.
# 2) GUI/GTK/webkit runtime - libwebkit2gtk-4.1-0 + libgtk-3-0 are the .deb's
#    only declared deps. The rest are the Tauri/WRY runtime closure that deb
#    does not declare (glib, x11, gdk-pixbuf, pango) plus fonts, so text renders
#    inside the container instead of falling back to tofu.
# 3) VNC stack for MODE=web and xauth/xset for MODE=x11.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates; \
    update-ca-certificates; \
    apt-get install -y --no-install-recommends \
      libwebkit2gtk-4.1-0 \
      libgtk-3-0 \
      libglib2.0-0 \
      libgdk-pixbuf-2.0-0 \
      libpango-1.0-0 \
      libcairo2 \
      libsoup-3.0-0 \
      libjavascriptcoregtk-4.1-0 \
      libx11-6 \
      libxext6 \
      libxrender1 \
      libxi6 \
      libxtst6 \
      libxrandr2 \
      libxfixes3 \
      libxcomposite1 \
      libxdamage1 \
      libxcursor1 \
      libgbm1 \
      libdrm2 \
      libegl1 \
      libgl1 \
      fonts-liberation \
      fonts-noto-core \
      xvfb \
      x11vnc \
      xauth \
      x11-xserver-utils \
      openbox \
      novnc \
      websockify \
      dbus-x11 \
      procps \
      curl \
      ca-certificates \
      git \
      openssh-client \
      unzip; \
    rm -rf /var/lib/apt/lists/*

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    TERM=xterm-256color

# Release assets are named OpenIDEA_<version>_<debian-arch>.deb, where
# debian-arch is amd64 / arm64 (Tauri bundler naming), NOT x86_64 / aarch64.
# Resolve the tag via the GitHub API when OPENIDEA_VERSION is empty.
# apt install of the local .deb resolves libwebkit2gtk-4.1-0 + libgtk-3-0.
RUN set -eux; \
    case "${TARGETARCH:-}" in \
      amd64) OI_ARCH=amd64 ;; \
      arm64) OI_ARCH=arm64 ;; \
      *) OI_ARCH=amd64 ;; \
    esac; \
    if [ -z "${OPENIDEA_VERSION}" ]; then \
      OPENIDEA_VERSION=$(curl -fsSL https://api.github.com/repos/l0ng-ai/openidea/releases/latest \
        | sed -n 's/.*"tag_name": "v\?\([^"]*\)".*/\1/p' | head -1); \
      echo "resolved latest OpenIDEA release: ${OPENIDEA_VERSION}"; \
    fi; \
    test -n "${OPENIDEA_VERSION}"; \
    OI_URL="https://github.com/l0ng-ai/openidea/releases/download/v${OPENIDEA_VERSION}/OpenIDEA_${OPENIDEA_VERSION}_${OI_ARCH}.deb"; \
    echo "fetching ${OI_URL}"; \
    curl -fsSL "${OI_URL}" -o /tmp/openidea.deb; \
    apt-get update; \
    apt-get install -y --no-install-recommends /tmp/openidea.deb; \
    rm -f /tmp/openidea.deb; \
    rm -rf /var/lib/apt/lists/*; \
    command -v openidea; \
    test -x /usr/bin/openidea

# Docker CLI client. The IDE's container dashboards need it plus the socket
# mount from docker-compose; without either they stay empty, which is harmless.
RUN set -eux; \
    DC_LATEST=$(curl -fsSL https://api.github.com/repos/docker/cli/releases/latest 2>/dev/null \
      | sed -n 's/.*"tag_name": "v\([^"]*\)".*/\1/p' | head -1); \
    DOCKER_CLI_VERSION="${DC_LATEST:-${DOCKER_CLI_VERSION}}"; \
    echo "docker CLI: ${DOCKER_CLI_VERSION}"; \
    case "${TARGETARCH:-}" in \
      arm64) DC_ARCH=aarch64 ;; \
      amd64) DC_ARCH=x86_64 ;; \
      *) DC_ARCH=x86_64 ;; \
    esac; \
    curl -fsSL "https://download.docker.com/linux/static/stable/${DC_ARCH}/docker-${DOCKER_CLI_VERSION}.tgz" -o /tmp/docker-cli.tgz; \
    tar -xzf /tmp/docker-cli.tgz -C /tmp; \
    install -m 0755 /tmp/docker/docker /usr/local/bin/docker; \
    rm -rf /tmp/docker /tmp/docker-cli.tgz; \
    docker --version

# Non-root runtime user (uid/gid 1000) and the mount target for user code.
RUN set -eux; \
    groupadd -g 1000 ide; \
    useradd -u 1000 -g 1000 -m -s /bin/sh ide; \
    mkdir -p /home/ide/project \
      /home/ide/.config/OpenIDEA \
      /home/ide/.cache/OpenIDEA \
      /home/ide/.local/share/OpenIDEA; \
    chown -R ide:ide /home/ide

COPY entrypoint.sh /usr/local/bin/openidea-entrypoint.sh
RUN sed -i 's/\r$//' /usr/local/bin/openidea-entrypoint.sh \
 && chmod 755 /usr/local/bin/openidea-entrypoint.sh

# Virtual display defaults; MODE picks the branch in the entrypoint.
ENV MODE=web \
    DISPLAY=:1 \
    XVFB_DISPLAY=:1 \
    XVFB_GEOMETRY=1440x900x24 \
    NOVNC_PORT=4190

EXPOSE 4190

USER ide
WORKDIR /home/ide/project

ENTRYPOINT ["/usr/local/bin/openidea-entrypoint.sh"]
CMD ["openidea"]