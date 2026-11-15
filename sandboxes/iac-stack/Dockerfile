# The iac-stack workstation: OpenTofu, a docker CLI pointed at dind, and the
# provider mirror that lets tofu init run offline.
FROM busybox:1.37.0-musl AS busybox
# The Lambda python runtime that floci starts functions from, loaded into dind
# by the lessons that need it.
FROM public.ecr.aws/lambda/python:3.12@sha256:3856536f53e945debf4c90d0ff301cbaa837c07a4ab9b0e2c102c6e54ceb9762 AS lambda-python

# Flattened in a stage of its own so the final image carries only the tar.
FROM debian:trixie-20261005-slim AS lambda-seed
COPY --from=lambda-python / /rootfs/
RUN tar -C /rootfs -cf /lambda-python.tar .

FROM debian:trixie-20261005-slim

ARG TOFU_VERSION=1.13.1
ARG DOCKER_CLI_VERSION=29.8.1

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl git jq unzip procps less nano vim-tiny \
    && rm -rf /var/lib/apt/lists/*

RUN arch=$(dpkg --print-architecture) \
    && curl -fsSL -o /tmp/tofu.zip \
       "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${arch}.zip" \
    && unzip -q /tmp/tofu.zip tofu -d /usr/local/bin \
    && rm /tmp/tofu.zip

RUN case "$(dpkg --print-architecture)" in amd64) a=x86_64 ;; arm64) a=aarch64 ;; esac \
    && curl -fsSL "https://download.docker.com/linux/static/stable/${a}/docker-${DOCKER_CLI_VERSION}.tgz" \
       | tar -xz -C /usr/local/bin --strip-components=1 docker/docker

COPY providers.tf /opt/providers/providers.tf
RUN cd /opt/providers \
    && tofu providers mirror /usr/local/share/tofu/providers \
    && rm -rf /opt/providers
COPY tofurc /etc/tofurc
ENV TF_CLI_CONFIG_FILE=/etc/tofurc

# A busybox root filesystem for dind. The static musl build needs nothing but
# its own binary and the applet links.
COPY --from=busybox /bin/busybox /opt/seed/rootfs/bin/busybox
RUN cd /opt/seed/rootfs \
    && mkdir -p tmp www data etc \
    && for a in $(bin/busybox --list); do [ "$a" = busybox ] || ln -s busybox "bin/$a"; done \
    && tar -C /opt/seed/rootfs -cf /opt/seed/busybox.tar . \
    && rm -rf /opt/seed/rootfs

COPY --from=lambda-seed /lambda-python.tar /opt/seed/lambda-python.tar
COPY load-lambda-runtime /usr/local/bin/load-lambda-runtime

RUN git config --system user.email dev@example.com \
    && git config --system user.name 'Dev' \
    && git config --system init.defaultBranch main

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
WORKDIR /root
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
