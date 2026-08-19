---
kind: lesson
title: "the small requests all work, and the one that matters hangs forever"
description: |
  Downloads from the artifact store are fine. Health checks are fine. Uploading
  a 1 MB build artifact to the same host, on the same connection, hangs until
  the client gives up. Nothing is down, nothing is slow, and no log line on
  either end says anything is wrong — because the packet that would have
  explained it was thrown away by a router in the middle.
name: mtu-blackhole
slug: mtu-blackhole
createdAt: "2026-08-11"

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
      systemctl stop far-store.service 2>/dev/null || true
      for ns in r1 r2 far; do ip netns del "$ns" 2>/dev/null || true; done
      for l in to-r1 r1-r2 r2-far; do ip link del "$l" 2>/dev/null || true; done
      ip route del 10.90.2.0/24 2>/dev/null || true
      install -d /opt/far /root/answers

      # Pinned, not assumed. With tcp_mtu_probing on, TCP eventually works out
      # the path MTU by itself after a stall, which would make the black hole
      # heal on its own and the lesson intermittent. 0 is the Debian default and
      # what the overwhelming majority of boxes run.
      sysctl -qw net.ipv4.tcp_mtu_probing=0

      ip netns add r1
      ip netns add r2
      ip netns add far

      # ---- the three links --------------------------------------------
      #
      #                 r1 --1400-->     -->
      # box --1500-- r1              r2       --1500-- far
      #                 r1 <--1500--     <--
      #
      # The middle link is the tunnel, and its two ends disagree: 1400 leaving
      # r1, 1500 leaving r2. That asymmetry is the scenario, and it is a real
      # one — somebody sized the near end for the encapsulation overhead and
      # left the far end at the default.
      #
      # It matters more than it looks. If both ends were 1400, r2 would squeeze
      # the return traffic too, far would be told the path MTU by r2's own
      # (unfiltered) ICMP, and it would then advertise a 1360-byte MSS on every
      # later connection — which caps what *this* box sends and quietly repairs
      # the upload. Measured: with a symmetric 1400 tunnel the black hole heals
      # itself after the first download. Squeezing only the outbound direction
      # keeps the far end ignorant, so it goes on offering 1460 and this box
      # goes on sending packets that cannot arrive.
      #
      # Both endpoints sit on 1500 and derive their MSS from the link they can
      # see. Neither of them can see this one.
      ip link add to-r1 type veth peer name r1-box
      ip link set r1-box netns r1
      ip addr add 10.90.0.1/24 dev to-r1
      ip link set to-r1 mtu 1500 up

      ip link add r1-r2 type veth peer name r2-r1
      ip link set r1-r2 netns r1
      ip link set r2-r1 netns r2

      ip link add r2-far type veth peer name far0
      ip link set r2-far netns r2
      ip link set far0 netns far

      # ---- r1: the near side of the tunnel ----------------------------
      #
      # The one rule in this lesson lives here. r1 is the router that has to
      # put a 1500-byte packet onto a 1400-byte link, and the ICMP it sends
      # back to say so never leaves the box. Every other kind of ICMP does,
      # which is why ping proves nothing here.
      ip netns exec r1 sh -c '
        ip link set lo up
        ip addr add 10.90.0.2/24 dev r1-box
        ip link set r1-box mtu 1500 up
        ip addr add 10.90.1.1/30 dev r1-r2
        ip link set r1-r2 mtu 1400 up
        ip route add 10.90.2.0/24 via 10.90.1.2
        sysctl -qw net.ipv4.ip_forward=1
        nft add table inet tunnel
        nft "add chain inet tunnel output { type filter hook output priority 0 ; policy accept ; }"
        nft add rule inet tunnel output icmp type destination-unreachable icmp code frag-needed drop
      '

      # ---- r2: the far side, wide open --------------------------------
      #
      # 1500 leaving r2, so nothing squeezes the return traffic and the store's
      # 1 MB download arrives untouched. This is why the failure is asymmetric:
      # there is only one narrow direction on this path.
      ip netns exec r2 sh -c '
        ip link set lo up
        ip addr add 10.90.1.2/30 dev r2-r1
        ip link set r2-r1 mtu 1500 up
        ip addr add 10.90.2.1/24 dev r2-far
        ip link set r2-far mtu 1500 up
        ip route add 10.90.0.0/24 via 10.90.1.1
        sysctl -qw net.ipv4.ip_forward=1
      '

      # ---- far: the artifact store ------------------------------------
      ip netns exec far sh -c '
        ip link set lo up
        ip addr add 10.90.2.9/24 dev far0
        ip link set far0 mtu 1500 up
        ip route add default via 10.90.2.1
      '

      ip route add 10.90.2.0/24 via 10.90.0.2 dev to-r1

      # ---- the service ------------------------------------------------
      cat > /opt/far/store.py <<'PY'
      import http.server

      BLOB = b"A" * 1000000


      class Store(http.server.BaseHTTPRequestHandler):
          protocol_version = "HTTP/1.1"

          def _send(self, body):
              self.send_response(200)
              self.send_header("Content-Type", "text/plain")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def do_GET(self):
              if self.path.startswith("/blob"):
                  self._send(BLOB)
              else:
                  self._send(b"artifact-store-2026\n")

          def do_PUT(self):
              self.do_POST()

          def do_POST(self):
              want = int(self.headers.get("Content-Length", "0"))
              got = 0
              while got < want:
                  chunk = self.rfile.read(min(65536, want - got))
                  if not chunk:
                      break
                  got += len(chunk)
              self._send(("stored bytes=%d\n" % got).encode())

          def log_message(self, *args):
              pass


      http.server.ThreadingHTTPServer(("10.90.2.9", 8080), Store).serve_forever()
      PY

      printf '[Unit]\nDescription=artifact store, behind the tunnel\nAfter=network.target\n\n[Service]\nNetworkNamespacePath=/run/netns/far\nExecStart=/usr/bin/python3 /opt/far/store.py\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' > /etc/systemd/system/far-store.service
      systemctl daemon-reload
      systemctl enable --now far-store.service >/dev/null 2>&1

      # The artifact the ticket is about. Zeros, so the file is boring and the
      # size is exact.
      dd if=/dev/zero of=/root/artifact.bin bs=1024 count=1024 2>/dev/null

      # Wait for the store to answer before handing the box over, so the first
      # command the student runs is not a false negative.
      for _ in $(seq 1 20); do
        ip netns exec far curl -s -m 1 http://10.90.2.9:8080/ 2>/dev/null \
          | grep -q artifact-store-2026 && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      CI cannot publish build artifacts to the store at 10.90.2.9:8080. It has
      been failing for two days. Everything else about that host looks fine.

      Works:

        curl -s http://10.90.2.9:8080/
        curl -s -o /dev/null -w '%{size_download}\n' http://10.90.2.9:8080/blob
        ping -c2 10.90.2.9

      Hangs until the client gives up:

        curl -s -m 10 --data-binary @/root/artifact.bin http://10.90.2.9:8080/upload

      A 1 MB download works and a 1 MB upload does not, to the same host, on the
      same port. The store logs nothing for the upload. Nobody has touched the
      firewall on either end.

      Two things to do.

      1. Make the upload complete. It must report the full 1048576 bytes.

      2. Write /root/answers/mtu.md, exactly two lines:

           path_mtu: <bytes>
           largest_df_payload: <bytes>

         path_mtu is the largest packet that can cross the whole path to
         10.90.2.9. largest_df_payload is the largest ICMP echo payload that
         survives the trip with fragmentation forbidden — the number you
         measured to arrive at the first one.

      The link between 10.90.0.2 and 10.90.1.2 is a tunnel run by another team.
      Its MTU is a fact about the transport, not a setting you own: it must
      still be what it is now when you are finished.

      The router in the middle will not tell you what is wrong. Measure it.
      Q

      echo "scenario ready — downloads fine, uploads hang"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      # ---- the tunnel is not yours ------------------------------------
      #
      # Only the narrow end is pinned. Reading it with ip -o, because a
      # /sys/class/net path is not visible the same way from inside a netns.
      near=$(ip netns exec r1 ip -o link show r1-r2 2>/dev/null | sed -n 's/.* mtu \([0-9]*\).*/\1/p')
      : "${near:=0}"

      if [ "$near" != "1400" ]; then
        echo "not yet: the tunnel is no longer 1400 bytes leaving 10.90.0.2 (now $near)."
        echo "         Widening the link does make the upload work, and it is the one"
        echo "         thing here you do not own. The overhead that made it 1400 is"
        echo "         still there; a real tunnel would just start dropping again."
        exit 1
      fi

      # ---- the traffic still goes the long way ------------------------
      hop=$(ip route get 10.90.2.9 2>/dev/null | head -1)
      if ! echo "$hop" | grep -q 'via 10.90.0.2'; then
        echo "not yet: traffic to 10.90.2.9 no longer goes via 10.90.0.2."
        echo "         The path through the tunnel is the exercise. Routing around it"
        echo "         or relaying through something else leaves the fault in place"
        echo "         for everything that still takes the original path."
        echo "         ip route get says: $hop"
        exit 1
      fi

      # ---- small request still works ----------------------------------
      small=$(curl -s -m 8 http://10.90.2.9:8080/ 2>/dev/null || true)
      if ! echo "$small" | grep -q 'artifact-store-2026'; then
        echo "not yet: the store at 10.90.2.9:8080 no longer answers a plain GET,"
        echo "         which it did before you started."
        exit 1
      fi

      # ---- the download that always worked still works ----------------
      down=$(curl -s -m 20 -o /dev/null -w '%{size_download}' http://10.90.2.9:8080/blob 2>/dev/null || echo 0)
      if [ "$down" != "1000000" ]; then
        echo "not yet: the 1 MB download that worked before now returns $down bytes."
        echo "         The return path was healthy. Whatever was changed took it out."
        exit 1
      fi

      # ---- the upload the ticket is about -----------------------------
      up=$(curl -s -m 25 --data-binary @/root/artifact.bin \
             http://10.90.2.9:8080/upload 2>/dev/null || true)
      if ! echo "$up" | grep -q 'stored bytes=1048576'; then
        echo "not yet: the 1 MB upload to 10.90.2.9:8080 still does not complete."
        if [ -z "$up" ]; then
          echo "         The store said nothing at all, which is what it says when the"
          echo "         request body never arrives. The connection opened, so this is"
          echo "         not reachability — it is the size of what is being sent."
        else
          echo "         The store said: $up"
        fi
        exit 1
      fi

      # ---- the measurement --------------------------------------------
      if [ ! -s /root/answers/mtu.md ]; then
        echo "not yet: /root/answers/mtu.md is missing or empty."
        echo "         The repair is half of this one. The other half is being able to"
        echo "         say what the path MTU is and how you know."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/mtu.md)
      pmtu=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*path_mtu[[:space:]]*[:=][[:space:]]*\([0-9]*\).*/\1/p' | head -1)
      dfp=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*largest_df_payload[[:space:]]*[:=][[:space:]]*\([0-9]*\).*/\1/p' | head -1)

      if [ -z "$pmtu" ]; then
        echo "not yet: no path_mtu line with a number in /root/answers/mtu.md."
        exit 1
      fi
      if [ -z "$dfp" ]; then
        echo "not yet: no largest_df_payload line with a number in /root/answers/mtu.md."
        exit 1
      fi

      fail=0

      if [ "$pmtu" != "1400" ]; then
        fail=1
        echo "not yet: you said path_mtu=$pmtu."
        case "$pmtu" in
          1500)
            echo "         1500 is the MTU of your own link — the number this box believed"
            echo "         all along, and believing it is what broke the upload. The path"
            echo "         MTU is the smallest link along the way, not the first one."
            ;;
          1360|1460)
            echo "         That is an MSS: the payload TCP will put in a segment. The MTU is"
            echo "         the whole packet, with the IP and TCP headers on it — 40 bytes"
            echo "         more than the MSS you are looking at."
            ;;
          1372)
            echo "         That is the ICMP payload that fit, not the packet that carried it."
            echo "         Add the 8-byte ICMP header and the 20-byte IP header."
            ;;
          *)
            echo "         Bisect it: ping -M do -s N, and find the N where the replies stop."
            echo "         Then account for the headers around that payload."
            ;;
        esac
      fi

      if [ "$dfp" != "1372" ]; then
        fail=1
        echo "not yet: you said largest_df_payload=$dfp."
        case "$dfp" in
          1400)
            echo "         1400 is the packet. -s takes the payload, and ping wraps it in"
            echo "         8 bytes of ICMP header and 20 bytes of IP header before it goes"
            echo "         out. The largest -s that survives is 28 less than that."
            ;;
          1472)
            echo "         1472 is what fits in a 1500-byte packet, which is what your own"
            echo "         link would allow. It does not survive this path — try it."
            ;;
          *)
            echo "         ping -M do -s N against 10.90.2.9, and find the largest N that"
            echo "         still gets a reply. -M do forbids fragmentation, so a packet too"
            echo "         big to forward is dropped instead of being cut up."
            ;;
        esac
      fi

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the 1 MB upload completes, the tunnel is still 1400 bytes wide, the"
      echo "       path still runs through it, and the path MTU is measured rather than"
      echo "       assumed."
