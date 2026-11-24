FROM kestra/kestra:v1.3.26

USER root

# Corporate proxy (Zscaler) intercepts TLS: its FULL CA chain must be trusted
# by every HTTPS consumer inside tasks and plugins (curl, git, JVM outbound).
# Same guard pattern as workspace/infrastructure/cicd/semaphore/Dockerfile:
# the chain is leaf -> short-lived intermediate -> long-lived intermediate
# -> root, and one cert is not enough - drop the whole chain (PEM .crt) into certs/.
COPY certs/ /usr/local/share/ca-certificates/

RUN set -eux; \
    n=$(find /usr/local/share/ca-certificates -name "*.crt" | wc -l); \
    echo "===> corporate CA certs found in certs/: $n"; \
    if [ "$n" -eq 0 ]; then \
      echo "FATAL: certs/ is empty - copy the Zscaler CA chain (PEM .crt) into" >&2; \
      echo "       workspace/infrastructure/cicd/kestra/certs/ and rebuild" >&2; \
      exit 1; \
    fi; \
    apk add --no-cache ca-certificates curl git bash docker-cli; \
    cat /usr/local/share/ca-certificates/*.crt >> /etc/ssl/certs/ca-certificates.crt; \
    update-ca-certificates

# Point every OpenSSL and JVM consumer at the refreshed bundle.
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt
ENV JAVA_TOOL_OPTIONS="-Djavax.net.ssl.trustStore=/etc/ssl/certs/java/cacerts -Djavax.net.ssl.trustStorePassword=changeit -Djavax.net.ssl.trustStoreType=JKS"

USER kestra
