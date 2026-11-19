FROM semaphoreui/semaphore:v2.20.24

ARG TARGETARCH=amd64
ARG TERRAFORM_VERSION=1.11.4

USER root

# Install docker-cli (for invoking deployer containers via docker.sock), curl, unzip, jq, and git
COPY certs/ /usr/local/share/ca-certificates/

# Corporate proxy (Zscaler) intercepts TLS: its FULL CA chain must be trusted
# BEFORE the first apk fetch (the apk index fetch runs over HTTPS). One cert is
# not enough - the chain is leaf -> short-lived intermediate -> long-lived
# intermediate -> root, and apk fails with "server certificate not trusted"
# unless every CA in the chain is dropped into certs/ as PEM.
RUN set -eux; \
    n=$(find /usr/local/share/ca-certificates -name '*.crt' | wc -l); \
    echo "===> corporate CA certs found in certs/: $n"; \
    if [ "$n" -eq 0 ]; then \
      echo "FATAL: certs/ is empty - copy the Zscaler CA chain (PEM .crt) into" >&2; \
      echo "       workspace/infrastructure/cicd/semaphore/certs/ and rebuild" >&2; \
      exit 1; \
    fi; \
    update-ca-certificates 2>/dev/null || cat /usr/local/share/ca-certificates/*.crt >> /etc/ssl/certs/ca-certificates.crt

# Point every OpenSSL consumer (apk, curl, terraform) at the refreshed bundle.
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt

RUN apk add --no-cache ca-certificates curl unzip docker-cli jq git
RUN update-ca-certificates

# Install Terraform from offline preinstall context if present, otherwise download from HashiCorp releases
RUN --mount=type=bind,from=preinstall,target=/preinstall \
    set -eux; \
    TF_ZIP=$(find /preinstall -maxdepth 2 -name "terraform_*_linux_${TARGETARCH}.zip" | head -n 1); \
    if [ -n "$TF_ZIP" ]; then \
      echo "Installing Terraform from offline store: $TF_ZIP"; \
      unzip -qo "$TF_ZIP" -d /usr/local/bin/; \
    else \
      echo "Offline zip not found in /preinstall; downloading Terraform ${TERRAFORM_VERSION}"; \
      curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" -o /tmp/tf.zip; \
      unzip -qo /tmp/tf.zip -d /usr/local/bin/; \
      rm -f /tmp/tf.zip; \
    fi; \
    chmod +x /usr/local/bin/terraform; \
    terraform -version

USER semaphore
