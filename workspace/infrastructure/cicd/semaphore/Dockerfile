FROM semaphoreui/semaphore:v2.20.24

ARG TARGETARCH=amd64
ARG TERRAFORM_VERSION=1.11.4

USER root

# Install docker-cli (for invoking deployer containers via docker.sock), curl, unzip, jq, and git
COPY certs/ /usr/local/share/ca-certificates/

# Trust the corporate CA BEFORE the first apk fetch (apk index fetch runs over TLS
# behind the corporate proxy). Regenerate the bundle when the tool exists;
# otherwise append the PEMs straight into the alpine bundle.
RUN update-ca-certificates 2>/dev/null || cat /usr/local/share/ca-certificates/*.crt >> /etc/ssl/certs/ca-certificates.crt

RUN apk add --no-cache ca-certificates curl unzip docker-cli jq git
RUN update-ca-certificates

# Install Terraform from offline preinstall context if present, otherwise download from HashiCorp releases
RUN --mount=type=bind,from=preinstall,target=/preinstall \
    set -eux; \
    TF_ZIP=$(find /preinstall -maxdepth 2 -name "terraform_*_linux_${TARGETARCH}.zip" | head -n 1); \
    if [ -n "$TF_ZIP" ]; then \
      echo "Installing Terraform from offline store: $TF_ZIP"; \
      unzip -q "$TF_ZIP" -d /usr/local/bin/; \
    else \
      echo "Offline zip not found in /preinstall; downloading Terraform ${TERRAFORM_VERSION}"; \
      curl -fsSL "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${TARGETARCH}.zip" -o /tmp/tf.zip; \
      unzip -q /tmp/tf.zip -d /usr/local/bin/; \
      rm -f /tmp/tf.zip; \
    fi; \
    chmod +x /usr/local/bin/terraform; \
    terraform -version

USER semaphore
