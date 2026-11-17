# The workstation for module 11: every client a supply chain has, in one box.
#
# The docker CLI drives the host's daemon through the mounted socket, so
# `docker build` and `docker push` behave exactly as on a laptop. crane, skopeo
# and cosign talk to the registry directly, with no daemon and no local cache in
# between — which is what makes them honest about what the registry holds.
# Trivy's vulnerability database, fetched once at build time so lessons scan
# offline, cut down to Python advisories published before trivy-prune's cutoff.
FROM aquasec/trivy:0.74.0 AS trivy
RUN trivy image --download-db-only --cache-dir /trivy

FROM golang:1.25-trixie AS trivydb
WORKDIR /src
COPY trivy-prune/ ./
COPY --from=trivy /trivy/db/ /full/
RUN go run . /full/trivy.db /tmp/trivy.db \
 && mkdir -p /trivy/db && mv /tmp/trivy.db /trivy/db/ && cp /full/metadata.json /trivy/db/

FROM debian:trixie-slim

ARG TARGETARCH
ARG CRANE_VERSION=0.21.9
ARG COSIGN_VERSION=3.1.2

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl jq socat less procps vim-tiny \
      docker-cli docker-buildx docker-compose skopeo apache2-utils \
      python3 python3-yaml python3-pip python3-venv \
    && rm -rf /var/lib/apt/lists/*

RUN case "$TARGETARCH" in amd64) a=x86_64 ;; arm64) a=arm64 ;; *) exit 1 ;; esac \
 && curl -fsSL "https://github.com/google/go-containerregistry/releases/download/v${CRANE_VERSION}/go-containerregistry_Linux_${a}.tar.gz" \
    | tar -xz -C /usr/local/bin crane \
 && curl -fsSL -o /usr/local/bin/cosign \
    "https://github.com/sigstore/cosign/releases/download/v${COSIGN_VERSION}/cosign-linux-${TARGETARCH}" \
 && chmod +x /usr/local/bin/cosign

COPY --from=trivy /usr/local/bin/trivy /usr/local/bin/trivy
COPY --from=anchore/syft:v1.52.0 /syft /usr/local/bin/syft
COPY --from=trivydb /trivy/ /opt/trivy/
# The box has no route to the advisory feeds, so scans use the baked database.
ENV TRIVY_CACHE_DIR=/opt/trivy TRIVY_SKIP_DB_UPDATE=true \
    TRIVY_SKIP_JAVA_DB_UPDATE=true TRIVY_OFFLINE_SCAN=true \
    TRIVY_DISABLE_VEX_NOTICE=true PIP_DISABLE_PIP_VERSION_CHECK=1

COPY defaults/ /opt/registry-defaults/
RUN ln -s /opt/registry-defaults/reset-registry /usr/local/bin/reset-registry \
 && ln -s /opt/registry-defaults/mkwheel /usr/local/bin/mkwheel
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

WORKDIR /work
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["sleep", "infinity"]
