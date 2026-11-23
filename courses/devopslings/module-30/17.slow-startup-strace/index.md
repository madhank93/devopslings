---
kind: lesson
title: "ten seconds of nothing, then it is fine"
description: |
  fx-rates takes ten seconds to start, every time, and then serves perfectly.
  The ticket asks for a longer start timeout. strace with timings shows where
  ten seconds of a startup that does almost nothing actually go: waiting on a
  nameserver that will never answer. Fix the lookup, not the timeout.
name: slow-startup-strace
slug: slow-startup-strace
createdAt: "2026-11-22"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      systemctl stop fx-rates.service 2>/dev/null || true
      systemctl reset-failed fx-rates.service 2>/dev/null || true
      rm -rf /etc/fx-rates.conf /usr/local/bin/fx-rates /etc/systemd/system/fx-rates.service \
             /root/answers/slow-startup.txt
      install -d /root/answers /var/lib/devopslings

      # The old site resolver was decommissioned with the DC2 network. Its
      # route still points at an interface that delivers nowhere, so queries
      # leave without error and are never answered.
      ip link del dc2 2>/dev/null || true
      ip link add dc2 type dummy
      ip link set dc2 up
      ip route replace 10.53.0.53/32 dev dc2

      # /etc/resolv.conf is a Docker bind mount: rewrite it in place, never by
      # rename, or the write fails with EBUSY.
      [ -f /var/lib/devopslings/resolv.conf.orig ] || cp /etc/resolv.conf /var/lib/devopslings/resolv.conf.orig
      [ -f /var/lib/devopslings/nsswitch.conf.orig ] || cp /etc/nsswitch.conf /var/lib/devopslings/nsswitch.conf.orig
      printf '# site resolvers (netcfg 2019)\nnameserver 10.53.0.53\n' > /etc/resolv.conf
      sed 's/^hosts:.*/hosts:          dns files/' /var/lib/devopslings/nsswitch.conf.orig > /etc/nsswitch.conf
      { grep -v 'rates-feed\.internal' /etc/hosts || true; } > /tmp/hosts.new
      cat /tmp/hosts.new > /etc/hosts
      echo '10.20.0.15  rates-feed.internal' >> /etc/hosts

      cat > /etc/fx-rates.conf <<'CONF'
      feed = rates-feed.internal
      listen = 127.0.0.1:8090
      CONF
      sha256sum /etc/fx-rates.conf | cut -d' ' -f1 > /var/lib/devopslings/slow-startup.sha256

      cat > /usr/local/bin/fx-rates <<'PY'
      #!/usr/bin/python3
      import http.server, json, socket

      conf = dict(l.split("=", 1) for l in open("/etc/fx-rates.conf") if "=" in l)
      conf = {k.strip(): v.strip() for k, v in conf.items()}
      feed_ip = socket.getaddrinfo(conf["feed"], 443, type=socket.SOCK_STREAM)[0][4][0]
      host, _, port = conf["listen"].rpartition(":")

      class H(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              body = json.dumps({"ready": True, "feed": feed_ip}).encode()
              self.send_response(200); self.end_headers(); self.wfile.write(body)
          def log_message(self, *a):
              pass

      http.server.HTTPServer((host, int(port)), H).serve_forever()
      PY
      chmod 0755 /usr/local/bin/fx-rates
      sha256sum /usr/local/bin/fx-rates | cut -d' ' -f1 >> /var/lib/devopslings/slow-startup.sha256

      cat > /etc/systemd/system/fx-rates.service <<'UNIT'
      [Unit]
      Description=FX rates cache

      [Service]
      ExecStart=/usr/local/bin/fx-rates
      Restart=on-failure
      UNIT
      systemctl daemon-reload
      systemctl start fx-rates.service

      echo "scenario ready — fx-rates.service takes about ten seconds to answer on 127.0.0.1:8090"
      echo "after every start. Write your findings to /root/answers/slow-startup.txt."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      ans=/root/answers/slow-startup.txt
      field() { { grep -iE "^$1=" "$ans" 2>/dev/null || true; } | tail -1 | cut -d= -f2- | tr -d ' "s'; }
      ns=$(field nameserver); to=$(field timeout_seconds)
      if [ -z "$ns" ] || [ -z "$to" ]; then
        echo "not yet: $ans needs nameserver=<address> and timeout_seconds=<n>: which server startup"
        echo "         waits on and how long each wait lasts, from strace -f -T of the service starting."
        exit 1
      fi
      if [ "$ns" != 10.53.0.53 ]; then
        echo "not yet: nameserver=$ns. The connect() just before each long wait in the trace names it."
        exit 1
      fi
      if [ "$to" != 5 ]; then
        echo "not yet: timeout_seconds=$to. -T prints the time spent in each call in <> at the end of"
        echo "         the line; look at the poll that returns 0 (Timeout)."
        exit 1
      fi

      sums=$(sha256sum /etc/fx-rates.conf /usr/local/bin/fx-rates 2>/dev/null | cut -d' ' -f1 || true)
      if [ "$sums" != "$(cat /var/lib/devopslings/slow-startup.sha256)" ]; then
        echo "not yet: /etc/fx-rates.conf or /usr/local/bin/fx-rates has changed. Every service on this"
        echo "         box resolves names the same way; the fix belongs in the resolver, not in one service."
        exit 1
      fi
      if grep -qE '^[[:space:]]*options.*timeout:0([^0-9]|$)' /etc/resolv.conf; then
        echo "not yet: options timeout:0 in /etc/resolv.conf. A zero timeout gives up on every nameserver"
        echo "         before it can answer, including working ones."
        exit 1
      fi
      if ! ip route get 10.53.0.53 2>/dev/null | grep -q 'dev dc2'; then
        echo "not yet: 10.53.0.53 no longer routes to dc2. That server is gone; the fix is to stop asking it,"
        echo "         not to change where its packets go."
        exit 1
      fi

      t0=$(date +%s%N)
      getent ahosts rates-feed.internal >/dev/null 2>&1 || true
      ms=$(( ($(date +%s%N) - t0) / 1000000 ))
      if [ "$ms" -ge 500 ]; then
        if grep -qE '^[[:space:]]*options.*(timeout|attempts):' /etc/resolv.conf; then
          echo "not yet: looking up rates-feed.internal still takes ${ms} ms. A shorter timeout shortens"
          echo "         each wait on 10.53.0.53; it does not stop the box asking it first."
        else
          echo "not yet: looking up rates-feed.internal takes ${ms} ms. The lookup still asks 10.53.0.53"
          echo "         before it gets to the answer the box already has."
        fi
        exit 1
      fi

      systemctl reset-failed fx-rates.service 2>/dev/null || true
      t0=$(date +%s%N)
      systemctl restart fx-rates.service
      body=""
      for _ in $(seq 1 150); do
        body=$(curl -fsS -m 1 http://127.0.0.1:8090/ 2>/dev/null || true)
        [ -n "$body" ] && break
        sleep 0.1
      done
      ms=$(( ($(date +%s%N) - t0) / 1000000 ))
      if [ -z "$body" ]; then
        echo "not yet: fx-rates did not answer on 127.0.0.1:8090 within 15 s of a restart."
        systemctl --no-pager status fx-rates.service 2>&1 | tail -4
        exit 1
      fi
      if [ "$(jq -r .feed <<<"$body")" != 10.20.0.15 ]; then
        echo "not yet: fx-rates resolved rates-feed.internal to $(jq -r .feed <<<"$body"), not 10.20.0.15."
        exit 1
      fi
      if [ "$ms" -ge 1000 ]; then
        echo "not yet: fx-rates took ${ms} ms from restart to its first answer; it should be under 1 s."
        exit 1
      fi
      echo "PASS — each lookup waited 5 s on 10.53.0.53; fx-rates now answers ${ms} ms after a restart,"
      echo "       with that server still unreachable."
---
