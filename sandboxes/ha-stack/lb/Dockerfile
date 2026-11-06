# A load-balancer node: HAProxy for the traffic, keepalived for the address.
FROM haproxy:3.0.11-bookworm
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends keepalived iproute2 procps curl iptables socat \
 && rm -rf /var/lib/apt/lists/*
COPY base.cfg /etc/haproxy/base.cfg
COPY supervise.sh /usr/local/bin/supervise
COPY lbctl /usr/local/bin/lbctl
ENTRYPOINT ["/usr/local/bin/supervise"]
