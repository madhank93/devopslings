---
kind: lesson
title: "the internal API that was answering the whole internet"
description: |
  Two services listen on the box: a customer portal that is meant to be public,
  and an internal metrics API — unauthenticated, because it was only ever meant
  to be read locally — that is bound to every interface and answering anyone who
  can route to the host. Auditing what a machine exposes and to whom is where a
  threat model begins. Restrict the API to loopback without taking down the
  portal that is supposed to be reachable.
name: attack-surface-audit
slug: attack-surface-audit
createdAt: "2026-08-26"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      set -e

      # Idempotent teardown
      systemctl stop portal.service metrics-api.service 2>/dev/null || true
      rm -f /etc/systemd/system/portal.service /etc/systemd/system/metrics-api.service
      rm -rf /opt/portal /opt/metrics /etc/metrics /root/answers/surface.md
      systemctl daemon-reload 2>/dev/null || true
      systemctl reset-failed portal.service metrics-api.service 2>/dev/null || true

      # Create directories
      install -d /opt/portal /opt/metrics /etc/metrics /root/answers

      # Write the public customer portal
      cat > /opt/portal/app.py <<'PY'
      import http.server, socketserver

      class H(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              self.send_response(200)
              self.end_headers()
              self.wfile.write(b"portal up\n")
          def log_message(self, *a):
              pass

      class S(socketserver.TCPServer):
          allow_reuse_address = True

      S(("0.0.0.0", 80), H).serve_forever()
      PY

      # Write the internal metrics API
      cat > /opt/metrics/api.py <<'PY'
      import http.server, socketserver

      addr = open("/etc/metrics/bind.conf").read().strip()
      host, port = addr.rsplit(":", 1)

      class H(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              self.send_response(200)
              self.end_headers()
              self.wfile.write(b"metrics: cpu=3% mem=41% disk=55%\n")
          def log_message(self, *a):
              pass

      class S(socketserver.TCPServer):
          allow_reuse_address = True

      S((host, int(port)), H).serve_forever()
      PY

      # Write the metrics bind config - MISCONFIGURED to all interfaces
      echo '0.0.0.0:9000' > /etc/metrics/bind.conf

      # Write both unit files
      cat > /etc/systemd/system/portal.service <<'UNIT'
      [Unit]
      Description=public customer portal
      [Service]
      ExecStart=/usr/bin/python3 /opt/portal/app.py
      Restart=on-failure
      UNIT

      cat > /etc/systemd/system/metrics-api.service <<'UNIT'
      [Unit]
      Description=internal metrics API
      [Service]
      ExecStart=/usr/bin/python3 /opt/metrics/api.py
      Restart=on-failure
      UNIT

      # Reload and start both
      systemctl daemon-reload
      systemctl start portal.service metrics-api.service

      # Write questions file
      cat > /root/questions.txt <<'Q'
      Two services listen on this box. Auditing what a machine exposes — and to whom —
      is where a threat model starts: every listening port is a door, and the question
      for each is who is supposed to be able to knock.

        $ ss -ltnp
        LISTEN 0 ... 0.0.0.0:80    ... python3   (portal.service)
        LISTEN 0 ... 0.0.0.0:9000  ... python3   (metrics-api.service)

        port 80   : the customer portal. Public by design — the internet is meant to
                    reach it.
        port 9000 : the internal metrics API. It reports cpu, memory and disk, and it
                    has no authentication because it was only ever meant to be read
                    from the box itself. It is listening on 0.0.0.0 — every interface —
                    so anyone who can route to this host can read it.

      The portal on 80 is correctly exposed; leave it. The metrics API on 9000 is
      exposed far beyond its purpose: an unauthenticated internal endpoint answering
      the whole network. Restrict it to the loopback interface so only the box itself
      can reach it, without taking it down — something still reads it locally.

      It binds the address in /etc/metrics/bind.conf; change it and restart:

        $ systemctl restart metrics-api

      Confirm the surface afterwards:

        $ ss -ltn | grep -E ':80|:9000'

      Then write /root/answers/surface.md with exactly four lines:

        port_80: <public or internal>
        port_9000: <public or internal>
        overexposed_port: <the port that was reachable beyond its purpose>
        restricted_to: <the interface you bound the metrics API to>
      Q

      echo "scenario ready — metrics API on 9000 exposed to every interface"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e

      ans=/root/answers/surface.md

      listen_addr() {
        # the bind address ss shows for a listening port, e.g. 127.0.0.1 or 0.0.0.0
        ss -ltn 2>/dev/null | awk -v p=":$1" '$4 ~ p"$" {print $4}' | sed "s/:$1\$//" | head -1
      }

      # The metrics API must have moved off every interface and onto loopback.
      # Poll briefly: a just-restarted service needs a moment to bind.
      m=""
      for _ in $(seq 1 20); do
        m=$(listen_addr 9000)
        [ -n "$m" ] && break
        sleep 0.5
      done
      if [ -z "$m" ]; then
        echo "not yet: nothing is listening on port 9000. The metrics API was to"
        echo "         be restricted to loopback, not shut off — something still"
        echo "         reads it locally. Set 127.0.0.1:9000 in /etc/metrics/bind.conf"
        echo "         and restart metrics-api."
        exit 1
      fi
      if [ "$m" != "127.0.0.1" ]; then
        echo "not yet: the metrics API is still listening on $m:9000 — reachable"
        echo "         from beyond the box. It is unauthenticated and internal;"
        echo "         bind it to 127.0.0.1 so only the box itself can reach it."
        exit 1
      fi

      # It still has to answer locally — restrict, don't remove.
      if ! curl -s -m 5 http://127.0.0.1:9000/ 2>/dev/null | grep -q metrics; then
        echo "not yet: the metrics API no longer answers on 127.0.0.1:9000. It"
        echo "         should still serve locally, just not to the whole network."
        exit 1
      fi

      # The portal must stay public — the fix is to restrict what is over-exposed,
      # not to lock down what is meant to be reached.
      p=$(listen_addr 80)
      if [ "$p" != "0.0.0.0" ] || ! curl -s -m 5 http://127.0.0.1/ 2>/dev/null | grep -q "portal up"; then
        echo "not yet: the public portal on port 80 is no longer reachable"
        echo "         (listening on '${p:-nothing}'). It is public by design —"
        echo "         restrict the metrics API, but leave the portal alone."
        exit 1
      fi

      # The written surface table.
      if [ ! -s "$ans" ]; then
        echo "not yet: /root/answers/surface.md is missing or empty."
        echo "         Four lines: port_80, port_9000, overexposed_port,"
        echo "         restricted_to."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      f() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | head -1; }
      a80=$(f port_80); a9000=$(f port_9000); aover=$(f overexposed_port); arestr=$(f restricted_to)

      if ! printf '%s' "$a80" | grep -q 'public'; then
        echo "not yet: port_80 should be classified public — it is the customer"
        echo "         portal, meant to face the internet."
        exit 1
      fi
      if ! printf '%s' "$a9000" | grep -q 'internal'; then
        echo "not yet: port_9000 should be classified internal — the metrics API"
        echo "         is meant to be read only from the box."
        exit 1
      fi
      if ! printf '%s' "$aover" | grep -q '9000'; then
        echo "not yet: overexposed_port should be 9000 — the port that was"
        echo "         reachable beyond its purpose."
        exit 1
      fi
      if ! printf '%s' "$arestr" | grep -qE '127\.0\.0\.1|loopback|localhost'; then
        echo "not yet: restricted_to should name the loopback interface you bound"
        echo "         the metrics API to (127.0.0.1)."
        exit 1
      fi

      echo "PASS — the public portal is still public, the internal metrics API is"
      echo "       now reachable only from the box, and the attack surface is"
      echo "       named for what it is."
