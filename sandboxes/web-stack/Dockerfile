# The box the web tier runs on: Debian with real systemd and a real nginx.
#
# nginx is the subject of this module rather than a detail of it, so it is the
# distribution package under systemd — `systemctl reload nginx`, an error log in
# the journal and in /var/log/nginx, and a worker running as www-data. An nginx
# started by hand as root in a foreground container would make the first lesson
# in the module impossible to teach: it is about the permissions a worker
# process has, and root has all of them.
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive \
    container=docker

RUN apt-get update && apt-get install -y --no-install-recommends \
      systemd systemd-sysv \
      nginx \
      procps psmisc lsof file less \
      curl ca-certificates openssl \
      python3 \
      iproute2 iputils-ping \
      socat netcat-openbsd \
      jq \
      vim-tiny nano \
      sudo \
    && rm -rf /var/lib/apt/lists/*

# nginx ships enabled and serving the Debian welcome page. Every lesson in this
# module writes its own site and starts the server itself, so the box begins
# with no listener and no configuration to unlearn.
RUN systemctl disable nginx.service \
    && rm -f /etc/nginx/sites-enabled/default \
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

# The upstream application every proxy lesson points at. It ships in the image
# rather than being written by each lesson's setup because it is the sandbox's
# other half: eight lessons need the same routes, the same upload endpoint and
# the same admin control, and a copy per lesson would drift.
#
# The admin API on 8081 is what makes a single-box lesson script able to reach
# across: a lesson's setup runs on the proxy, and this is how it tells the
# upstream to go slow, go away, or say what it received.
COPY app/upstream.py /opt/upstream/upstream.py
COPY app/upstream.service /etc/systemd/system/upstream.service
RUN systemctl enable upstream.service

# Persist the journal so `journalctl -u nginx` has history rather than only
# whatever happened since the last restart.
RUN mkdir -p /var/log/journal && systemd-tmpfiles --create

STOPSIGNAL SIGRTMIN+3
CMD ["/sbin/init"]
