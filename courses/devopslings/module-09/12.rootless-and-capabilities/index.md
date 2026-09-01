---
kind: lesson
title: "it needed one privileged thing, so it runs privileged"
description: |
  The shaper sets an MTU and a queueing discipline on its own interface, which
  needs a capability the default set does not include. It got --privileged, and
  it works. Learn what that actually handed it, and how to give it the one thing
  it asked for.
name: rootless-and-capabilities
slug: rootless-and-capabilities
createdAt: "2026-09-01"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      proj=devopslings-caps

      cat > shape.sh <<'SH'
      #!/bin/sh
      # Egress shaper. Applies the profile this pod is supposed to run under.
      set -e
      ip link set dev eth0 mtu 1400
      tc qdisc add dev eth0 root tbf rate 1mbit burst 32kbit latency 400ms
      echo "shaped: mtu=$(cat /sys/class/net/eth0/mtu) qdisc=$(tc qdisc show dev eth0 | head -1 | awk '{print $2}')"
      SH
      chmod +x shape.sh

      cat > Dockerfile <<'DOCKER'
      FROM alpine:3.20
      RUN apk add --no-cache iproute2 libcap
      COPY shape.sh /shape.sh
      CMD ["/shape.sh"]
      DOCKER

      # It failed with "Operation not permitted", someone added privileged: true,
      # and it has worked ever since.
      cat > compose.yaml <<'YAML'
      services:
        shaper:
          build: .
          privileged: true
      YAML

      docker compose -p "$proj" down -v --remove-orphans >/dev/null 2>&1 || true

      echo "scenario ready — files are in $(pwd)"
      echo
      echo "See what it runs as:"
      echo "  docker compose -p $proj run --rm shaper"
      echo "  docker compose -p $proj run --rm --entrypoint sh shaper -c 'capsh --decode=\$(awk \"/CapEff/{print \\\$2}\" /proc/self/status)'"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      proj=devopslings-caps
      want_hex=0000000000001000   # CAP_NET_ADMIN, and nothing else
      expected='shaped: mtu=1400 qdisc=tbf'

      for f in shape.sh Dockerfile compose.yaml; do
        if [ ! -f "$f" ]; then
          echo "not yet: no $f in $(pwd)"
          exit 1
        fi
      done

      docker compose -p "$proj" down -v --remove-orphans >/dev/null 2>&1 || true
      if ! build_out=$(docker compose -p "$proj" build 2>&1); then
        echo "not yet: the image does not build:"
        printf '%s\n' "$build_out" | tail -10 | sed 's/^/    /'
        exit 1
      fi

      # It still has to do its job. A profile that is locked down and cannot
      # shape anything has solved the wrong problem.
      code=0
      out=$(docker compose -p "$proj" run --rm shaper 2>&1) || code=$?
      if [ "$code" != "0" ] || ! printf '%s' "$out" | grep -q "$expected"; then
        echo "not yet: the shaper does not do its job any more (exit $code):"
        printf '%s\n' "$out" | tail -8 | sed 's/^/    /'
        echo "It needs CAP_NET_ADMIN to set an MTU or a qdisc — that capability is not"
        echo "in the default set, which is why this started with privileged: true."
        exit 1
      fi

      probe() {
        docker compose -p "$proj" run --rm --entrypoint sh shaper -c "$1" 2>/dev/null | tr -d '\r'
      }

      # What the compose file declares, and what the container ends up holding.
      declared=$(docker compose -p "$proj" config 2>/dev/null | grep -c 'privileged: true' || true)

      capeff=$(probe 'awk "/^CapEff/ {print \$2}" /proc/self/status' | tail -1)
      if [ -z "$capeff" ]; then
        echo "not yet: could not read the container's effective capabilities"
        exit 1
      fi

      if [ "$capeff" = "000001ffffffffff" ] || [ "${declared:-0}" != "0" ]; then
        echo "not yet: this is still privileged. That is not 'a few more permissions' —"
        echo "it is every capability the kernel has, the device tree, and the seccomp"
        echo "and AppArmor profiles switched off. Grant the one it asked for."
        exit 1
      fi

      if [ "$capeff" != "$want_hex" ]; then
        echo "not yet: the container's effective capabilities are $capeff, and the"
        echo "shaper needs exactly one ($want_hex, CAP_NET_ADMIN). It currently holds:"
        probe 'capsh --decode=$(awk "/^CapEff/ {print \$2}" /proc/self/status) 2>/dev/null | tail -1' \
          | sed 's/^/    /' || true
        echo "Drop everything first, then add back only what the job needs."
        exit 1
      fi

      # The behavioural half: a capability it was not given has to be one it
      # cannot use. CAP_SYS_ADMIN is the one privileged: true was really handing
      # over.
      mounted=$(probe 'mount -t tmpfs none /mnt >/dev/null 2>&1 && echo yes || echo no' | tail -1)
      if [ "$mounted" != "no" ]; then
        echo "not yet: the container can still mount filesystems, so it still has"
        echo "CAP_SYS_ADMIN. Whatever is granting that is granting far more than an MTU."
        exit 1
      fi

      echo "PASS — the shaper works with CAP_NET_ADMIN and nothing else, and cannot"
      echo "mount a filesystem any more."
---
