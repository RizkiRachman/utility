# syntax=docker/dockerfile:1
# Kestra image - corporate CA chain + optional lightweight plugin set.
#
# KESTRA_BASE  : base image. Default is the LIGHT variant (no plugin catalog,
#                ~229MB vs ~3GB); the 107 core plugins (log, kv, inputs,
#                scripts, flow control) are built in either way.
# KESTRA_PLUGINS: optional space-separated extra plugins to install at build,
#                e.g. io.kestra.plugin:plugin-git:LATEST (needed for Git
#                namespace sync). Empty by default.
ARG KESTRA_BASE=kestra/kestra:v1.3.26-no-plugins
FROM ${KESTRA_BASE}
ARG KESTRA_PLUGINS=""

USER root

# Corporate proxy (Zscaler) intercepts TLS: the FULL CA chain must be trusted
# by system consumers (apt/curl/git) AND by the JVM (plugins install, outbound
# HTTPS from tasks). Same guard pattern as workspace/infrastructure/cicd/semaphore.
COPY certs/ /usr/local/share/ca-certificates/

RUN set -eux; \
    n=$(find /usr/local/share/ca-certificates -name "*.crt" | wc -l); \
    echo "===> corporate CA certs found in certs/: $n"; \
    if [ "$n" -eq 0 ]; then \
      echo "FATAL: certs/ is empty - copy the Zscaler CA chain (PEM .crt) into" >&2; \
      echo "       workspace/infrastructure/cicd/kestra/certs/ and rebuild" >&2; \
      exit 1; \
    fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl git bash; \
    rm -rf /var/lib/apt/lists/*; \
    cat /usr/local/share/ca-certificates/*.crt >> /etc/ssl/certs/ca-certificates.crt; \
    update-ca-certificates; \
    for c in /usr/local/share/ca-certificates/*.crt; do \
      keytool -importcert -noprompt -alias "corp-$(basename "$c" .crt)" \
        -keystore /opt/java/openjdk/lib/security/cacerts -storepass changeit -file "$c"; \
    done

# Point system consumers at the refreshed bundle. The JVM uses the imported
# cacerts above - no javax.net.ssl.trustStore override needed.
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

RUN if [ -n "$KESTRA_PLUGINS" ]; then /app/kestra plugins install $KESTRA_PLUGINS; fi

USER kestra
