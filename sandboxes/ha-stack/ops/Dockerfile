# The student's box: every client tool the module uses, plus the docker CLI
# to crash, freeze and partition the other nodes.
FROM quay.io/coreos/etcd:v3.5.21 AS etcd
FROM docker:27.5.1-cli AS docker
FROM postgres:17.6-bookworm
RUN apt-get update \
 && apt-get install -y --no-install-recommends curl jq python3 iproute2 procps less nano vim-tiny iputils-ping \
 && rm -rf /var/lib/apt/lists/*
COPY --from=etcd /usr/local/bin/etcdctl /usr/local/bin/
COPY --from=docker /usr/local/bin/docker /usr/local/bin/
COPY node gapwatch ha-reset /usr/local/bin/
# No ETCDCTL_ENDPOINTS: etcdctl refuses to run when it and --endpoints are both
# set, and which member a command asks is half of what the etcd lessons teach.
ENV PGHOST=pg1 PGUSER=postgres PGPASSWORD=devopslings PGDATABASE=shop
WORKDIR /ha
# /ha is a volume shared with every node; defaults/ seeds it once.
CMD ["bash", "-c", "[ -f /ha/.seeded ] || { cp -rn /defaults/. /ha/ && touch /ha/.seeded; }; exec sleep infinity"]
