---
kind: lesson
title: "half the egress works, and the other half broke when you fixed it"
description: |
  Nothing on this box reaches the internet without going through the egress
  proxy, and nothing internal reaches anything if it does. One environment
  variable turns each of those on, and the file it is written in decides
  whether a systemd service ever sees it.
name: through-a-proxy
slug: through-a-proxy
createdAt: "2026-08-19"

sandbox:
  stack: netlab
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e

      # ---- clean slate -------------------------------------------------
      systemctl stop egress-proxy.service inventory.service vendor-api.service 2>/dev/null || true
      systemctl disable stock-sync.service 2>/dev/null || true
      rm -rf /etc/systemd/system/stock-sync.service.d
      for ns in proxy intra ext; do ip netns del "$ns" 2>/dev/null || true; done
      for l in to-proxy to-intra proxy-ext; do ip link del "$l" 2>/dev/null || true; done
      ip route del unreachable 10.91.2.0/24 2>/dev/null || true
      install -d /opt/vendor /opt/net /root/answers /var/lib/stock-sync
      : > /var/log/egress-proxy.log

      ip netns add proxy
      ip netns add intra
      ip netns add ext

      # ---- the three legs ----------------------------------------------
      #
      #   box --10.91.0.0/24-- proxy --10.91.2.0/24-- ext (api.vendor.example)
      #    |
      #    +---10.91.1.0/24--- intra (inventory.corp)
      #
      # Nothing forwards anywhere. The proxy is a proxy, not a router: it has a
      # leg on the outside and a leg on the inside and it opens its own
      # connections. That is why it cannot reach 10.91.1.0/24 — nobody gave it a
      # route, and in a real network nobody would.
      ip link add to-proxy type veth peer name proxy0
      ip link set proxy0 netns proxy
      ip addr add 10.91.0.1/24 dev to-proxy
      ip link set to-proxy up

      ip link add to-intra type veth peer name intra0
      ip link set intra0 netns intra
      ip addr add 10.91.1.1/24 dev to-intra
      ip link set to-intra up

      ip link add proxy-ext type veth peer name ext0
      ip link set proxy-ext netns proxy
      ip link set ext0 netns ext

      ip netns exec proxy sh -c '
        ip link set lo up
        ip addr add 10.91.0.2/24 dev proxy0
        ip link set proxy0 up
        ip addr add 10.91.2.1/24 dev proxy-ext
        ip link set proxy-ext up
      '

      ip netns exec intra sh -c '
        ip link set lo up
        ip addr add 10.91.1.5/24 dev intra0
        ip link set intra0 up
      '

      ip netns exec ext sh -c '
        ip link set lo up
        ip addr add 10.91.2.9/24 dev ext0
        ip link set ext0 up
        ip route add default via 10.91.2.1
      '

      # The perimeter, in one line. Everything outside is unreachable from this
      # box by design — a route that answers ENETUNREACH immediately stands in
      # for the firewall that would otherwise drop it silently.
      ip route add unreachable 10.91.2.0/24

      # Names, because a proxy is configured with names and NO_PROXY is matched
      # against them.
      grep -v -e 'api\.vendor\.example' -e 'inventory\.corp' /etc/hosts > /tmp/hosts.new || true
      cat /tmp/hosts.new > /etc/hosts
      rm -f /tmp/hosts.new
      printf '10.91.2.9 api.vendor.example\n10.91.1.5 inventory.corp\n' >> /etc/hosts

      # ---- the two origin servers --------------------------------------
      cat > /opt/net/serve.py <<'PY'
      import http.server
      import sys

      addr, port, body = sys.argv[1], int(sys.argv[2]), sys.argv[3].encode()


      class Origin(http.server.BaseHTTPRequestHandler):
          protocol_version = "HTTP/1.1"

          def do_GET(self):
              self.send_response(200)
              self.send_header("Content-Type", "text/plain")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def log_message(self, *args):
              pass


      http.server.ThreadingHTTPServer((addr, port), Origin).serve_forever()
      PY

      # ---- the proxy ----------------------------------------------------
      #
      # A forward proxy in forty lines: it takes an absolute URI, opens its own
      # connection to the origin, and relays. Every request is logged with the
      # host that was asked for, which is what makes "did this go through the
      # proxy" a question with an answer rather than an opinion.
      cat > /opt/net/proxy.py <<'PY'
      import datetime
      import http.server
      import socket
      import urllib.parse

      LOG = "/var/log/egress-proxy.log"


      class Proxy(http.server.BaseHTTPRequestHandler):
          protocol_version = "HTTP/1.0"

          def note(self, verdict):
              with open(LOG, "a") as fh:
                  stamp = datetime.datetime.now().isoformat(timespec="seconds")
                  fh.write("%s %s %s %s\n" % (stamp, self.command, self.path, verdict))

          def do_GET(self):
              parts = urllib.parse.urlsplit(self.path)
              if not parts.netloc:
                  self.note("400-not-absolute")
                  self.send_error(400, "absolute URI required")
                  return
              try:
                  up = socket.create_connection(
                      (parts.hostname, parts.port or 80), 4)
              except OSError as exc:
                  self.note("502-%s" % exc.__class__.__name__)
                  self.send_error(502, "proxy cannot reach %s" % parts.hostname)
                  return
              self.note("200")
              path = parts.path or "/"
              if parts.query:
                  path = path + "?" + parts.query
              up.sendall(("GET %s HTTP/1.0\r\nHost: %s\r\nConnection: close\r\n\r\n"
                          % (path, parts.netloc)).encode())
              while True:
                  chunk = up.recv(65536)
                  if not chunk:
                      break
                  self.wfile.write(chunk)
              up.close()

          def log_message(self, *args):
              pass


      http.server.ThreadingHTTPServer(("10.91.0.2", 3128), Proxy).serve_forever()
      PY

      unit() {
        printf '[Unit]\nDescription=%s\nAfter=network.target\n\n[Service]\nNetworkNamespacePath=/run/netns/%s\nExecStart=%s\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' \
          "$1" "$2" "$3" > "/etc/systemd/system/$4"
      }

      unit "vendor rates API, outside the perimeter" ext \
        "/usr/bin/python3 /opt/net/serve.py 10.91.2.9 80 rates-2026-08-19-usd-1.00" \
        vendor-api.service
      unit "inventory service, inside" intra \
        "/usr/bin/python3 /opt/net/serve.py 10.91.1.5 8080 stock-ok" \
        inventory.service
      unit "egress proxy" proxy \
        "/usr/bin/python3 /opt/net/proxy.py" \
        egress-proxy.service

      # ---- the job that has to work ------------------------------------
      #
      # Vendor-shipped and checksummed. The fix is not in here: a job that has
      # to be edited every time the network changes is the thing proxy
      # environment variables exist to avoid.
      cat > /opt/vendor/stock-sync <<'SYNC'
      #!/bin/sh
      # Shipped by the vendor. Do not edit.
      install -d /var/lib/stock-sync
      out=/var/lib/stock-sync/last.txt

      # curl prints 000 through -w when it never got a response, so its exit
      # status is deliberately ignored rather than turned into a second reading.
      code() {
        curl -sS -m 8 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true
      }

      v=$(code http://api.vendor.example/rates)
      i=$(code http://inventory.corp:8080/stock)

      if [ "$v" = "200" ]; then vs=ok; else vs="fail($v)"; fi
      if [ "$i" = "200" ]; then is=ok; else is="fail($i)"; fi

      printf 'vendor=%s internal=%s\n' "$vs" "$is" > "$out"
      cat "$out"
      SYNC
      chmod 755 /opt/vendor/stock-sync
      sha256sum /opt/vendor/stock-sync | awk '{print $1}' > /opt/vendor/stock-sync.sha256

      printf '[Unit]\nDescription=nightly stock sync\nAfter=network.target\n\n[Service]\nType=oneshot\nExecStart=/opt/vendor/stock-sync\n' \
        > /etc/systemd/system/stock-sync.service

      # ---- the half-configured box --------------------------------------
      #
      # Somebody put the proxy in /etc/environment when the perimeter went up.
      # Login shells get it and services do not, and nothing was ever said
      # about the traffic that must not go through it.
      grep -v -i -e '^http_proxy=' -e '^https_proxy=' -e '^no_proxy=' /etc/environment \
        > /tmp/env.new 2>/dev/null || true
      cat /tmp/env.new > /etc/environment
      rm -f /tmp/env.new
      printf 'http_proxy=http://10.91.0.2:3128\nHTTP_PROXY=http://10.91.0.2:3128\n' >> /etc/environment

      systemctl daemon-reload
      systemctl enable --now vendor-api.service inventory.service egress-proxy.service >/dev/null 2>&1

      for _ in $(seq 1 20); do
        ip netns exec proxy curl -s -m 1 -o /dev/null http://10.91.2.9/rates 2>/dev/null \
          && curl -s -m 1 -o /dev/null http://10.91.1.5:8080/stock 2>/dev/null && break
        sleep 0.5
      done
      : > /var/log/egress-proxy.log

      cat > /root/questions.txt <<'Q'
      Since the perimeter went up, this box reaches nothing outside without the
      egress proxy at http://10.91.0.2:3128. Two things are wrong, and they look
      like opposites.

      In a login shell, the vendor API works and the internal one does not:

        $ curl -sS -o /dev/null -w '%{http_code}\n' http://api.vendor.example/rates
        200
        $ curl -sS -o /dev/null -w '%{http_code}\n' http://inventory.corp:8080/stock
        502

      The nightly job, which calls both, is the other way round:

        $ systemctl start stock-sync.service
        $ cat /var/lib/stock-sync/last.txt
        vendor=fail(000) internal=ok

      Three things to do.

      1. Make `systemctl start stock-sync.service` write:

           vendor=ok internal=ok

         /opt/vendor/stock-sync is shipped by the vendor and checksummed. It is
         not where the fix goes.

      2. Make a login shell get both right too. The box's global environment is
         /etc/environment; that is the file the shell answer belongs in.

      3. Write /root/answers/proxy.md, exactly two lines:

           internal_via_proxy_status: <the status the proxy returns for
                                       inventory.corp>
           service_ignores: <the file a systemd service does not read>

      Traffic to api.vendor.example must go through the proxy, and traffic to
      inventory.corp must not. The proxy log at /var/log/egress-proxy.log names
      every host it is asked for, and it is how both halves are graded.

      The unreachable route to 10.91.2.0/24 is the perimeter. It is not yours,
      and it must still be there when you are finished.
      Q

      echo "scenario ready — half the egress works, and it is a different half in each shell"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      # ---- the perimeter is not yours ----------------------------------
      #
      # Asked as a connection rather than as a route: what matters is that this
      # box still cannot reach the outside on its own, however that is arranged.
      direct=$(env -u http_proxy -u HTTP_PROXY -u all_proxy -u ALL_PROXY \
                 curl -sS -m 4 -o /dev/null -w '%{http_code}' \
                 http://10.91.2.9/rates 2>/dev/null || true)
      if [ "$direct" = "200" ]; then
        echo "not yet: this box now reaches 10.91.2.9 directly, without the proxy."
        echo "         The unreachable route to 10.91.2.0/24 is the perimeter. Routing"
        echo "         around it makes the symptom disappear and is not a thing you can"
        echo "         do to a real firewall."
        exit 1
      fi

      # ---- the vendor job is the vendor's ------------------------------
      want=$(cat /opt/vendor/stock-sync.sha256 2>/dev/null || echo missing)
      have=$(sha256sum /opt/vendor/stock-sync 2>/dev/null | awk '{print $1}')
      if [ "$want" != "$have" ]; then
        echo "not yet: /opt/vendor/stock-sync has been edited."
        echo "         It is shipped and checksummed. Proxy settings that live inside"
        echo "         a job have to be found and changed again in every job — which"
        echo "         is the problem the environment variables solve."
        exit 1
      fi

      # ---- the service ---------------------------------------------------
      before=$(wc -l < /var/log/egress-proxy.log 2>/dev/null || echo 0)

      rm -f /var/lib/stock-sync/last.txt
      systemctl start stock-sync.service >/dev/null 2>&1 || true
      result=$(cat /var/lib/stock-sync/last.txt 2>/dev/null || true)

      if [ "$result" != "vendor=ok internal=ok" ]; then
        echo "not yet: stock-sync.service reported:"
        echo "           ${result:-nothing at all}"
        case "$result" in
          *"vendor=fail(000)"*)
            echo "         vendor=fail(000) is no HTTP response whatsoever: the request"
            echo "         never reached anything. The service is still trying to go"
            echo "         direct, into the unreachable route. It has an environment,"
            echo "         and it is not the one your shell has."
            ;;
          *"internal=fail(502)"*)
            echo "         502 comes from the proxy itself — it accepted the request and"
            echo "         could not reach inventory.corp, because nothing routes from"
            echo "         the proxy to the inside. That traffic has to skip the proxy."
            ;;
        esac
        exit 1
      fi

      run=$(tail -n "+$((before + 1))" /var/log/egress-proxy.log 2>/dev/null || true)

      if ! echo "$run" | grep -q 'api.vendor.example'; then
        echo "not yet: the job succeeded, but the proxy never saw api.vendor.example."
        echo "         Something is carrying that traffic around the proxy. The"
        echo "         perimeter is there so that nothing can; if it did, it would"
        echo "         stop working the moment this box met a real firewall."
        exit 1
      fi

      if echo "$run" | grep -q 'inventory.corp'; then
        echo "not yet: the job sent inventory.corp to the proxy:"
        echo "         $(echo "$run" | grep inventory.corp | head -1)"
        echo "         It worked, so somebody taught the proxy a route to the inside."
        echo "         Internal traffic is supposed to bypass the proxy, not be"
        echo "         carried by it — that is what NO_PROXY is for."
        exit 1
      fi

      # ---- the login shell -----------------------------------------------
      #
      # /etc/environment is read for login sessions, so the shell half is graded
      # by loading exactly that file and nothing else.
      before=$(wc -l < /var/log/egress-proxy.log)

      shell_code() {
        ( set -a
          . /etc/environment 2>/dev/null
          set +a
          curl -sS -m 8 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null || true )
      }

      vcode=$(shell_code http://api.vendor.example/rates)
      icode=$(shell_code http://inventory.corp:8080/stock)

      if [ "$vcode" != "200" ]; then
        echo "not yet: with /etc/environment loaded, http://api.vendor.example/rates"
        echo "         returns $vcode. It returned 200 before you started — the proxy"
        echo "         setting that made external traffic work has been lost."
        exit 1
      fi

      if [ "$icode" != "200" ]; then
        echo "not yet: with /etc/environment loaded, http://inventory.corp:8080/stock"
        echo "         returns $icode."
        if [ "$icode" = "502" ]; then
          echo "         Still going through the proxy, which cannot reach the inside."
          echo "         curl matches NO_PROXY against the host in the URL — the name,"
          echo "         not the address it resolves to."
        fi
        exit 1
      fi

      run=$(tail -n "+$((before + 1))" /var/log/egress-proxy.log 2>/dev/null || true)
      if ! echo "$run" | grep -q 'api.vendor.example'; then
        echo "not yet: the shell reached the vendor without the proxy seeing it."
        exit 1
      fi
      if echo "$run" | grep -q 'inventory.corp'; then
        echo "not yet: the shell still sends inventory.corp to the proxy. It answered"
        echo "         this time, which means the proxy was given a way inside. The"
        echo "         request should not be reaching it at all."
        exit 1
      fi

      # ---- the two answers -----------------------------------------------
      if [ ! -s /root/answers/proxy.md ]; then
        echo "not yet: /root/answers/proxy.md is missing or empty."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/proxy.md)
      status=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*internal_via_proxy_status[[:space:]]*[:=][[:space:]]*\([0-9]*\).*/\1/p' | head -1)
      ignores=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*service_ignores[[:space:]]*[:=][[:space:]]*\(.*\)$/\1/p' | head -1)

      fail=0

      case "$status" in
        502)
          ;;
        "")
          fail=1
          echo "not yet: no internal_via_proxy_status line with a number in the answer."
          ;;
        000)
          fail=1
          echo "not yet: you said internal_via_proxy_status=$status."
          echo "         000 is curl's way of saying no HTTP response arrived at all."
          echo "         The proxy did answer — it is reachable, it just could not get"
          echo "         where it was asked to go. Ask it and read the status:"
          echo "           curl -sS -o /dev/null -w '%{http_code}\\n' \\"
          echo "                -x http://10.91.0.2:3128 http://inventory.corp:8080/stock"
          ;;
        *)
          fail=1
          echo "not yet: you said internal_via_proxy_status=$status."
          echo "           curl -sS -o /dev/null -w '%{http_code}\\n' \\"
          echo "                -x http://10.91.0.2:3128 http://inventory.corp:8080/stock"
          ;;
      esac

      case "$ignores" in
        *environment*)
          ;;
        "")
          fail=1
          echo "not yet: no service_ignores line in the answer."
          ;;
        *bashrc*|*profile*|*bash_profile*)
          fail=1
          echo "not yet: you said service_ignores=$ignores."
          echo "         True, and it is true of every non-login process. The file being"
          echo "         asked about is the box-wide one that login shells *do* read and"
          echo "         that systemd services still do not."
          ;;
        *)
          fail=1
          echo "not yet: you said service_ignores=$ignores."
          echo "         The proxy was already configured for people logging in. Find"
          echo "         where that was written, and name the file the service never"
          echo "         read:"
          echo "           systemctl show stock-sync.service -p Environment"
          ;;
      esac

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the job and the shell both reach the vendor through the proxy and the"
      echo "       inventory service around it, the vendor's script is untouched, and the"
      echo "       perimeter is still in place."
