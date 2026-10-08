# The workstation for module 11: every client a supply chain has, in one box.
#
# The docker CLI drives the host's daemon through the mounted socket, so
# `docker build` and `docker push` behave exactly as on a laptop. crane, skopeo
# and cosign talk to the registry directly, with no daemon and no local cache in
# between — which is what makes them honest about what the registry holds.
FROM debian:trixie-slim

ARG TARGETARCH
ARG CRANE_VERSION=0.21.9
ARG COSIGN_VERSION=3.1.2

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl jq socat less procps vim-tiny \
      docker-cli docker-buildx docker-compose skopeo apache2-utils \
    && rm -rf /var/lib/apt/lists/*

RUN case "$TARGETARCH" in amd64) a=x86_64 ;; arm64) a=arm64 ;; *) exit 1 ;; esac \
 && curl -fsSL "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_${a}.tar.gz" \
    | tar -xz -C /usr/local/bin crane \
 && curl -fsSL -o /usr/local/bin/cosign \
    "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${TARGETARCH}" \
 && chmod +x /usr/local/bin/cosign

COPY defaults/ /opt/registry-defaults/
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
