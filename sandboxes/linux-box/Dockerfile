# A small Debian box that runs real systemd as PID 1.
#
# Most "Linux in a container" teaching images run a shell as PID 1, which makes
# every systemd lesson a lie: there is no journal to read, `systemctl status`
# does not exist, and unit ordering cannot be demonstrated. Since diagnosing a
# failed unit from its journal is one of the things a DevOps engineer actually
# does daily, the box runs the real thing.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker

RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv \
      cron \
      procps psmisc lsof file less \
      iproute2 iputils-ping curl ca-certificates \
      sudo \
      openssl \
      jq \
      lvm2 e2fsprogs \
      faketime \
      vim-tiny nano \
      sysstat \
      python3 \
      openssh-server openssh-client \
    && rm -rf /var/lib/apt/lists/*

# systemd in a container should not try to manage hardware, the network, or
# logins. Masking these keeps boot fast and the journal readable — an unmasked
# box floods the journal with failures that have nothing to do with the lesson,
# which is exactly the noise the student is being taught to see through.
RUN systemctl mask \
      systemd-udevd.service \
      systemd-udev-trigger.service \
      systemd-modules-load.service \
      systemd-network-generator.service \
      systemd-firstboot.service \
      getty.target \
      console-getty.service \
    && rm -f /lib/systemd/system/multi-user.target.wants/* \
    && rm -f /etc/systemd/system/*.wants/*

# openssh-server ships enabled and would start on every box. Only the SSH
# hardening lesson wants it, and it enables the service itself; leaving it off
# keeps the daemon and its host-key generation out of every other lesson's
# journal.
#
# The privilege-separation directory is created by a tmpfiles rule rather than
# left to the service's RuntimeDirectory, so `sshd -t` works before the daemon
# has ever started — the lesson has the learner validate the config first.
RUN systemctl disable ssh.service 2>/dev/null || true \
    && printf 'd /run/sshd 0755 root root -\n' > /etc/tmpfiles.d/sshd.conf

# Persist the journal to disk so `journalctl -b` has history to show. The
# default volatile journal is wiped on restart, which would erase the evidence
# a lesson asks the student to find.
RUN mkdir -p /var/log/journal && systemd-tmpfiles --create

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
