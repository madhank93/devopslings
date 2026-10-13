---
kind: lesson
title: "port 443 is open, and HTTP/3 cannot get through it"
description: |
  The shop moved to an edge proxy that speaks HTTP/3. Browsers are fine. The
  mobile team's QUIC-only client cannot connect at all, and the firewall has
  had "allow 443" in it for years. It does allow 443 — for one of the two
  transport protocols that can use it.
name: http3-cannot-get-through
slug: http3-cannot-get-through
createdAt: "2026-10-13"

sandbox:
  stack: netlab
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      set -e

      # ---- clean slate -------------------------------------------------
      systemctl stop shop-web.service udp-echo.service edge-fw.service 2>/dev/null || true
      systemctl disable edge-fw.service 2>/dev/null || true
      systemctl reset-failed shop-web.service udp-echo.service edge-fw.service 2>/dev/null || true
      for l in to-web to-mobile; do ip link del "$l" 2>/dev/null || true; done
      for ns in web mobile; do ip netns del "$ns" 2>/dev/null || true; done
      nft delete table inet edge 2>/dev/null || true
      rm -rf /etc/shop /var/lib/shop-caddy /etc/netns/mobile /etc/netns/web
      rm -f /etc/edge-fw.nft /etc/systemd/system/shop-web.service \
            /etc/systemd/system/udp-echo.service /etc/systemd/system/edge-fw.service \
            /root/shop-ca.crt
      install -d /etc/shop /var/lib/shop-caddy /etc/netns/mobile /etc/netns/web

      # ---- the topology ------------------------------------------------
      #
      #   mobile 10.85.0.20 ── to-mobile ─ this box (router + firewall) ─ to-web ── web 10.84.0.10
      #                                                                          shop.lab :443 tcp+udp
      mk_ns() {
        ns=$1 link=$2 net=$3 host=$4
        ip netns add "$ns"
        ip link add "$link" type veth peer name eth0 netns "$ns"
        ip addr add "$net.1/24" dev "$link"
        ip link set "$link" up
        ip netns exec "$ns" ip link set lo up
        ip netns exec "$ns" ip addr add "$net.$host/24" dev eth0
        ip netns exec "$ns" ip link set eth0 up
        ip netns exec "$ns" ip route add default via "$net.1"
      }
      mk_ns web to-web 10.84.0 10
      mk_ns mobile to-mobile 10.85.0 20

      # ip netns exec bind-mounts /etc/netns/NAME/* over /etc, so both sides
      # resolve shop.lab without touching the box's own hosts file.
      printf '127.0.0.1 localhost\n10.84.0.10 shop.lab\n' > /etc/netns/mobile/hosts
      cp /etc/netns/mobile/hosts /etc/netns/web/hosts

      # ---- the service -------------------------------------------------
      cat > /etc/shop/Caddyfile <<'CADDY'
      {
        local_certs
        skip_install_trust
        admin off
      }
      shop.lab {
        tls internal
        respond "shop-answers-2026 {http.request.proto}"
      }
      CADDY

      printf '[Unit]\nDescription=shop.lab edge proxy (HTTP/1.1, HTTP/2, HTTP/3)\nAfter=network.target\n\n[Service]\nNetworkNamespacePath=/run/netns/web\nEnvironment=XDG_DATA_HOME=/var/lib/shop-caddy XDG_CONFIG_HOME=/var/lib/shop-caddy\nExecStart=/usr/bin/caddy run --config /etc/shop/Caddyfile --adapter caddyfile\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/shop-web.service

      # Something else on the web tier that listens on UDP and must stay
      # unreachable from outside: the firewall's reason for existing.
      printf '[Unit]\nDescription=internal UDP status responder on the web tier\nAfter=network.target\n\n[Service]\nNetworkNamespacePath=/run/netns/web\nExecStart=/usr/bin/socat UDP-RECVFROM:9999,fork SYSTEM:"echo status-ok"\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/udp-echo.service

      # ---- the firewall ------------------------------------------------
      cat > /etc/edge-fw.nft <<'NFT'
      #!/usr/sbin/nft -f
      # Edge firewall for the web tier. Loaded at boot by edge-fw.service.

      destroy table inet edge

      table inet edge {
        chain forward {
          type filter hook forward priority filter; policy accept;
          ip daddr 10.84.0.0/24 jump to_web
        }

        chain to_web {
          ct state established,related accept

          # HTTP and HTTPS
          tcp dport { 80, 443 } accept

          # INC-1907: UDP reflection flood against the web tier.
          # Nothing behind here speaks UDP to the outside.
          meta l4proto udp counter drop

          counter drop
        }
      }
      NFT

      printf '[Unit]\nDescription=edge firewall (/etc/edge-fw.nft)\nAfter=network-pre.target\nBefore=network.target\n\n[Service]\nType=oneshot\nRemainAfterExit=yes\nExecStart=/usr/sbin/nft -f /etc/edge-fw.nft\nExecReload=/usr/sbin/nft -f /etc/edge-fw.nft\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/edge-fw.service

      sysctl -qw net.ipv4.ip_forward=1
      systemctl daemon-reload
      systemctl enable --now edge-fw.service >/dev/null 2>&1
      systemctl start udp-echo.service shop-web.service

      # Caddy mints its local CA on first start; hand the client its root.
      CA=/var/lib/shop-caddy/caddy/pki/authorities/local/root.crt
      for _ in $(seq 1 40); do [ -s "$CA" ] && break; sleep 0.5; done
      cp "$CA" /root/shop-ca.crt
      for _ in $(seq 1 40); do
        ip netns exec mobile curl -s -m 2 --cacert /root/shop-ca.crt https://shop.lab/ 2>/dev/null \
          | grep -q shop-answers-2026 && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      shop.lab moved to a new edge proxy last week. It speaks HTTP/1.1, HTTP/2
      and HTTP/3. This box is the router and firewall in front of it; the
      "mobile" namespace is a client out on the internet.

      Browsers are happy:

        ip netns exec mobile curl -s --cacert /root/shop-ca.crt https://shop.lab/

      The mobile team's new SDK speaks only HTTP/3, and it cannot connect:

        ip netns exec mobile curl -sS -m 5 --http3-only --cacert /root/shop-ca.crt https://shop.lab/

      From inside the web tier, HTTP/3 works fine. The firewall has allowed
      443 for years (/etc/edge-fw.nft, loaded at boot by edge-fw.service).

      Make the HTTP/3-only client work, and keep it working after a reboot.

      The web tier also runs an internal UDP service on port 9999. It must stay
      unreachable from outside, as must every other UDP port: the flood the
      firewall was written for is still out there.
      Q

      echo "scenario ready — HTTP/2 through the firewall works, HTTP/3 does not"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      CURL="ip netns exec mobile curl -s -m 5 --cacert /root/shop-ca.crt"

      if ! systemctl is-active --quiet shop-web.service; then
        echo "not yet: shop-web.service is not running.  journalctl -u shop-web.service -n 20"
        exit 1
      fi

      # ---- the firewall still does its job ------------------------------
      echo_reply=$(echo ping | ip netns exec mobile timeout 3 socat -T2 - UDP:10.84.0.10:9999 2>/dev/null || true)
      if printf '%s' "$echo_reply" | grep -q status-ok; then
        echo "not yet: the internal UDP service on 10.84.0.10:9999 answers from outside."
        echo "         HTTP/3 needs UDP 443. The firewall was written to keep every"
        echo "         other UDP port shut, and now it does not."
        exit 1
      fi

      h2=$($CURL https://shop.lab/ 2>/dev/null || true)
      if ! printf '%s' "$h2" | grep -q shop-answers-2026; then
        echo "not yet: ordinary HTTPS from the mobile client no longer works:"
        echo "           ${h2:-no response}"
        echo "         It did when you started."
        exit 1
      fi

      # ---- HTTP/3 ------------------------------------------------------
      h3=$($CURL -S --http3-only https://shop.lab/ 2>&1 || true)
      if ! printf '%s' "$h3" | grep -q 'shop-answers-2026 HTTP/3'; then
        echo "not yet: the HTTP/3-only client still cannot reach shop.lab:"
        echo "           $(printf '%s' "$h3" | head -1)"
        drops=$(nft list chain inet edge to_web 2>/dev/null | grep 'udp counter' | grep -o 'packets [0-9]*' | head -1 | cut -d' ' -f2 || true)
        echo "         HTTP/3 is QUIC, and QUIC runs over UDP. Follow one attempt"
        echo "         through the chain the firewall sends it into, rule by rule:"
        echo "           nft list chain inet edge to_web"
        [ -n "$drops" ] && echo "         (the UDP drop rule has matched $drops packets so far)"
        exit 1
      fi

      # ---- and after a reboot ------------------------------------------
      #
      # Load the boot file into an empty namespace and compare it with what is
      # running. Counters are left out; rules, order and sets are compared.
      ip netns del fwcheck 2>/dev/null || true
      ip netns add fwcheck
      booted=$(ip netns exec fwcheck sh -c 'nft -f /etc/edge-fw.nft && nft -s list table inet edge' 2>&1 || true)
      ip netns del fwcheck 2>/dev/null || true
      running=$(nft -s list table inet edge 2>/dev/null || true)
      if [ "$booted" != "$running" ]; then
        echo "not yet: HTTP/3 works now, and /etc/edge-fw.nft does not load the ruleset"
        echo "         that is running. edge-fw.service loads that file at boot, so the"
        echo "         next reboot puts the old firewall back. Difference (boot file <"
        echo "         > running):"
        diff <(printf '%s\n' "$booted") <(printf '%s\n' "$running") | grep '^[<>]' | head -12 | sed 's/^/           /' || true
        exit 1
      fi

      echo "PASS — HTTP/3 and HTTP/2 both reach shop.lab, every other UDP port is still"
      echo "       dropped, and the boot file loads exactly the ruleset that is running."
