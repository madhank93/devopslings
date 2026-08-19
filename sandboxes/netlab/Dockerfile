# A small Debian box that runs real systemd as PID 1, with networking tools.
#
# This box exists so the network path can be built by hand — namespaces, veth
# pairs, a bridge — rather than described. It runs real systemd for the same
# reason linux-box does, because several lessons diagnose a service that is bound
# to the wrong interface or is not draining its accept queue, and that needs real
# units.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker

RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv \
      procps psmisc lsof file less \
      iproute2 iputils-ping iputils-tracepath ethtool \
      nftables iptables \
      conntrack \
      tcpdump \
      socat netcat-openbsd \
      curl ca-certificates openssl \
      bind9-dnsutils dnsmasq \
      python3 \
      jq \
      vim-tiny nano \
      sudo \
    && rm -rf /var/lib/apt/lists/*

# systemd in a container should not try to manage hardware, the network, or
# logins. Masking these keeps boot fast and the journal readable — an unmasked
# box floods the journal with failures that have nothing to do with the lesson,
# which is exactly the noise the student is being taught to see through.
#
# dnsmasq is installed for module 05 — resolution, search domains and ndots need
# a resolver that answers for real rather than an /etc/hosts entry pretending to.
# Debian enables it on install; it is disabled here so that a box which is not
# running a DNS lesson resolves through Docker's resolver exactly as before.
RUN systemctl disable dnsmasq.service \
    && systemctl mask \
      systemd-udevd.service \
      systemd-udev-trigger.service \
      systemd-modules-load.service \
      systemd-network-generator.service \
      systemd-firstboot.service \
      getty.target \
      console-getty.service \
    && rm -f /lib/systemd/system/multi-user.target.wants/* \
    && rm -f /etc/systemd/system/*.wants/*

# Persist the journal to disk so `journalctl -b` has history to show. The
# default volatile journal is wiped on restart, which would erase the evidence
# a lesson asks the student to find.
RUN mkdir -p /var/log/journal && systemd-tmpfiles --create

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
