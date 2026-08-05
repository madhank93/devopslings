---
kind: lesson
title: "the tuning that works until something re-reads the config"
description: |
  edge-proxy needs a shorter TCP keepalive. Someone set it with `sysctl -w`, it
  took effect, and the ticket was closed. It is back to the default now, and
  writing it to a file is not enough either — something else is setting it back.
name: sysctl-that-survives
slug: sysctl-that-survives
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      install -d /etc/sysctl.d /var/lib/devopslings /root/answers

      rm -f /etc/sysctl.d/*edge*.conf /etc/sysctl.d/99-vendor-net.conf 2>/dev/null || true

      # A vendor drop-in from the base image build, sorting late enough to win
      # against anything obvious a person adds. Nobody remembers it exists.
      cat > /etc/sysctl.d/99-vendor-net.conf <<'CONF'
      # Installed by acme-baseline 4.2. Do not edit; managed by configuration.
      net.ipv4.tcp_keepalive_time = 7200
      net.ipv4.tcp_keepalive_intvl = 75
      CONF

      # Someone's earlier attempt: a file that is read, applied, and then
      # overwritten a moment later by the one above.
      cat > /etc/sysctl.d/10-edge-proxy.conf <<'CONF'
      # Shorter keepalive so dead peers are noticed before the LB gives up.
      net.ipv4.tcp_keepalive_time = 120
      CONF

      systemctl restart systemd-sysctl.service >/dev/null 2>&1 || true

      printf '/etc/sysctl.d/99-vendor-net.conf\n' > /var/lib/devopslings/sysctl.override
      printf '120\n' > /var/lib/devopslings/sysctl.want

      cat > /root/questions.txt <<'Q'
      edge-proxy needs net.ipv4.tcp_keepalive_time set to 120, so a dead peer is
      noticed before the load balancer gives up on the connection.

      Someone already added /etc/sysctl.d/10-edge-proxy.conf saying exactly
      that. The running value is still 7200.

        /root/answers/override   the full path of the file that is overriding it

      Then make 120 the value that is actually in effect, and make it stay that
      way when the sysctl configuration is applied again.

      The check re-applies the configuration the way a boot does and re-reads
      the value. `sysctl -w` on its own will not survive that.
      Q

      echo "scenario ready — 10-edge-proxy.conf asks for 120 and the running value is $(cat /proc/sys/net/ipv4/tcp_keepalive_time)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      want=$(cat /var/lib/devopslings/sysctl.want)
      want_file=$(cat /var/lib/devopslings/sysctl.override)

      if [ ! -s /root/answers/override ]; then
        echo "not yet: /root/answers/override is missing or empty"
        echo "         which file is setting net.ipv4.tcp_keepalive_time back to 7200?"
        echo "         'sysctl --system' prints each file as it applies it, in order."
        exit 1
      fi
      got_file=$(tr -d '[:space:]' < /root/answers/override)
      if [ "$got_file" != "$want_file" ]; then
        echo "not yet: /root/answers/override says '$got_file'"
        echo "         expected the file that is applied AFTER 10-edge-proxy.conf and sets"
        echo "         the same key. Run 'sysctl --system' and read the order."
        exit 1
      fi

      # The value must be right now.
      now=$(cat /proc/sys/net/ipv4/tcp_keepalive_time)
      if [ "$now" != "$want" ]; then
        echo "not yet: net.ipv4.tcp_keepalive_time is $now, expected $want"
        exit 1
      fi

      # And it must survive the configuration being applied again, which is what
      # a boot does. This is the step `sysctl -w` fails.
      systemctl restart systemd-sysctl.service >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1
      sleep 1
      after=$(cat /proc/sys/net/ipv4/tcp_keepalive_time)
      if [ "$after" != "$want" ]; then
        echo "not yet: the value was $want, and after the configuration was re-applied it"
        echo "         is $after."
        echo "         Something in /etc/sysctl.d is still winning. Files are applied in"
        echo "         lexicographic order and the last write to a key is the one that"
        echo "         sticks — so the fix has to sort after whatever is overriding it,"
        echo "         or the override has to stop setting it."
        exit 1
      fi

      # It has to come from configuration, not from a live write that happens to
      # be in place.
      src=$(grep -rlE '^[[:space:]]*net\.ipv4\.tcp_keepalive_time[[:space:]]*=[[:space:]]*'"$want" \
        /etc/sysctl.d /etc/sysctl.conf 2>/dev/null | head -1 || true)
      if [ -z "$src" ]; then
        echo "not yet: the running value is $want, and no file under /etc/sysctl.d or"
        echo "         /etc/sysctl.conf sets it."
        echo "         'sysctl -w' changes the running kernel and nothing else — the next"
        echo "         boot, or the next time this configuration is applied, loses it."
        exit 1
      fi

      echo "PASS — net.ipv4.tcp_keepalive_time is $want, set by $src, and it survives the"
      echo "       configuration being applied again."
---
