# The student's box: every client tool the module uses, plus the docker CLI
# to crash, freeze and partition the other nodes.
FROM quay.io/coreos/etcd:v3.5.21 AS etcd
FROM docker:27.5.1-cli AS docker
FROM openbao/openbao:2.6.4 AS bao
FROM restic/restic:0.19.1 AS restic
FROM postgres:17.6-bookworm
ARG TARGETARCH
ARG TOFU_VERSION=1.13.2
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl git jq python3 iproute2 procps less nano vim-tiny iputils-ping ca-certificates \
 && rm -rf /var/lib/apt/lists/*
# OpenTofu, with the providers modules 23 and 27 use mirrored into the image,
# so `tofu init` works offline. Module 27's pipeline also runs this image as a
# CI job container, which is why it carries the docker provider.
RUN curl -fsSL --retry 5 --retry-all-errors "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${TARGETARCH}.tar.gz" \
    | tar -xz -C /usr/local/bin tofu \
 && mkdir -p /tmp/m && printf 'terraform {\n  required_providers {\n    postgresql = { source = "cyrilgdn/postgresql", version = "1.27.0" }\n    docker = { source = "kreuzwerker/docker", version = "4.6.0" }\n  }\n}\n' > /tmp/m/main.tf \
 && { tofu -chdir=/tmp/m providers mirror /usr/share/tofu-mirror \
      || { sleep 10; tofu -chdir=/tmp/m providers mirror /usr/share/tofu-mirror; } \
      || { sleep 30; tofu -chdir=/tmp/m providers mirror /usr/share/tofu-mirror; }; } \
 && rm -rf /tmp/m
COPY tofurc /etc/tofurc
ENV TF_CLI_CONFIG_FILE=/etc/tofurc
COPY --from=etcd /usr/local/bin/etcdctl /usr/local/bin/
COPY --from=docker /usr/local/bin/docker /usr/local/bin/
COPY --from=bao /usr/bin/bao /usr/local/bin/
COPY --from=restic /usr/bin/restic /usr/local/bin/
COPY node gapwatch ha-reset scratchdb /usr/local/bin/
# No ETCDCTL_ENDPOINTS: etcdctl refuses to run when it and --endpoints are both
# set, and which member a command asks is half of what the etcd lessons teach.
ENV PGHOST=pg1 PGUSER=postgres PGPASSWORD=devopslings PGDATABASE=shop BAO_ADDR=http://bao:8200
WORKDIR /ha
# /ha is a volume shared with every node; defaults/ seeds it once.
CMD ["bash", "-c", "[ -f /ha/.seeded ] || { cp -rn /defaults/. /ha/ && touch /ha/.seeded; }; exec sleep infinity"]
