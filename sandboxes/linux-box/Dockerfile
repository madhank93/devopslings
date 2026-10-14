# The clean target for module 15's molecule lesson: the stock image plus the
# python3 that Ansible needs on a managed host. See the COPY below.
# Its setuid bits are stripped: copied into the box, those binaries belong to no
# package there, and module 07's setuid audits would rightly flag them.
FROM debian:trixie-slim AS molecule-target
RUN apt-get update && apt-get install -y --no-install-recommends python3 \
    && rm -rf /var/lib/apt/lists/* \
    && find / -xdev -type f -perm /6000 -exec chmod ug-s {} +

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
      fail2ban \
      ansible-core python3-apt \
      git python3-venv \
    && rm -rf /var/lib/apt/lists/*

# Module 15's role lesson tests a role with molecule from a clean target. There
# is no docker in the box, so each molecule instance is a chroot holding a
# fresh copy of a pristine debian:trixie-slim rootfs, reached through
# community.general's chroot connection. molecule is not packaged in Debian.
COPY --from=molecule-target / /opt/molecule-target/
RUN python3 -m venv --system-site-packages /opt/molecule \
    && /opt/molecule/bin/pip install --no-cache-dir molecule==26.9.0 \
    && ln -s /opt/molecule/bin/molecule /usr/local/bin/molecule \
    && ansible-galaxy collection install -p /usr/share/ansible/collections \
         community.general:==13.4.0

# Module 15 installs nginx "from nothing" with Ansible, and grading must work
# without the internet. The packages wait, uninstalled, in a local apt archive
# that is already a configured source; a lesson only has to `apt-get update`.
# The index is written by hand because dpkg-dev is not in the image.
RUN mkdir -p /srv/mirror && cd /srv/mirror \
    && apt-get update \
    && apt-get download nginx nginx-common \
    && for f in *.deb; do \
         dpkg-deb -f "$f" | sed '/^$/d'; \
         echo "Filename: ./$f"; \
         echo "Size: $(stat -c %s "$f")"; \
         echo "SHA256: $(sha256sum "$f" | cut -d' ' -f1)"; \
         echo; \
       done > Packages \
    && echo "deb [trusted=yes] copy:/srv/mirror ./" > /etc/apt/sources.list.d/mirror.list \
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

# fail2ban ships enabled and would start a daemon that expects a working
# firewall backend; its lesson analyses jails with fail2ban-regex and
# fail2ban-client offline, so the daemon stays off.
RUN systemctl disable fail2ban.service 2>/dev/null || true

# Persist the journal to disk so `journalctl -b` has history to show. The
# default volatile journal is wiped on restart, which would erase the evidence
# a lesson asks the student to find.
RUN mkdir -p /var/log/journal && systemd-tmpfiles --create

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
