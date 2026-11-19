# syntax=docker/dockerfile:1
FROM semaphoreui/semaphore:v2.20.24

ARG TARGETARCH=amd64
ARG TERRAFORM_VERSION=1.11.4

USER root

# Install docker-cli (for invoking deployer containers via docker.sock), curl, unzip, jq, and git
RUN apk add --no-cache curl unzip docker-cli jq git

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
