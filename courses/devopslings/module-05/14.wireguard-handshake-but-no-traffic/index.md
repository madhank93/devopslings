---
kind: lesson
title: "the VPN handshake is fresh, and the network behind it is unreachable"
description: |
  The site-to-site tunnel to the datacenter is up: a handshake every couple of
  minutes, and the far end's tunnel address answers ping. The servers behind it
  do not. Adding the obvious route makes the error message stranger, not
  shorter — because in WireGuard a route only gets a packet to the tunnel. The
  tunnel decides for itself who is allowed to receive it.
name: wireguard-handshake-but-no-traffic
slug: wireguard-handshake-but-no-traffic
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
      K=/var/lib/wg-lesson

      # ---- clean slate -------------------------------------------------
      systemctl stop wg-quick@wg0.service dc-app.service 2>/dev/null || true
      systemctl disable wg-quick@wg0.service 2>/dev/null || true
      systemctl reset-failed wg-quick@wg0.service dc-app.service 2>/dev/null || true
      ip link del wg0 2>/dev/null || true
      ip link del to-dc 2>/dev/null || true
      ip netns del dc 2>/dev/null || true
      ip route del 10.87.0.0/24 2>/dev/null || true
      rm -rf "$K" /srv/dc /etc/wireguard/wg0.conf
      rm -f /etc/systemd/system/dc-app.service
      install -d -m 700 "$K" /etc/wireguard
      install -d /srv/dc

      # ---- the underlay ------------------------------------------------
      #
      #   office (this box)                         dc (namespace)
      #   to-dc 192.168.86.1/30 ─── the "internet" ─── uplink 192.168.86.2/30
      #   wg0   10.86.0.1/24  ═════ tunnel ═════════  wg0    10.86.0.2/24
      #                                               app0   10.87.0.10/24  (the servers)
      ip netns add dc
      ip link add to-dc type veth peer name uplink netns dc
      ip addr add 192.168.86.1/30 dev to-dc
      ip link set to-dc up
      ip netns exec dc sh -c '
        ip link set lo up
        ip addr add 192.168.86.2/30 dev uplink
        ip link set uplink up
        ip link add app0 type dummy
        ip addr add 10.87.0.10/24 dev app0
        ip link set app0 up
      '

      # ---- keys --------------------------------------------------------
      umask 077
      wg genkey > "$K/office.key"; wg pubkey < "$K/office.key" > "$K/office.pub"
      wg genkey > "$K/dc.key";     wg pubkey < "$K/dc.key"     > "$K/dc.pub"
      umask 022

      # ---- the datacenter end ------------------------------------------
      #
      # Configured correctly: it accepts the office's tunnel address and
      # keeps the tunnel warm, which is why the handshake always looks fresh.
      ip netns exec dc ip link add wg0 type wireguard
      ip netns exec dc wg set wg0 \
        listen-port 51820 private-key "$K/dc.key" \
        peer "$(cat "$K/office.pub")" \
          endpoint 192.168.86.1:51820 \
          allowed-ips 10.86.0.1/32 \
          persistent-keepalive 25
      ip netns exec dc ip addr add 10.86.0.2/24 dev wg0
      ip netns exec dc ip link set wg0 up

      echo "dc-app-answers-2026" > /srv/dc/index.html
      printf '[Unit]\nDescription=application servers behind the datacenter tunnel\nAfter=network.target\n\n[Service]\nNetworkNamespacePath=/run/netns/dc\nExecStart=/usr/bin/python3 -m http.server 8080 --bind 10.87.0.10 --directory /srv/dc\nRestart=always\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/dc-app.service

      # ---- the office end ----------------------------------------------
      cat > /etc/wireguard/wg0.conf <<CONF
      # Site-to-site tunnel: office <-> datacenter. Managed by wg-quick@wg0.
      [Interface]
      Address = 10.86.0.1/24
      ListenPort = 51820
      PrivateKey = $(cat "$K/office.key")

      [Peer]
      # dc-gw01
      PublicKey = $(cat "$K/dc.pub")
      Endpoint = 192.168.86.2:51820
      AllowedIPs = 10.86.0.2/32
      CONF
      chmod 600 /etc/wireguard/wg0.conf

      systemctl daemon-reload
      systemctl enable --now wg-quick@wg0.service >/dev/null 2>&1
      systemctl start dc-app.service

      for _ in $(seq 1 30); do
        ping -c1 -W1 10.86.0.2 >/dev/null 2>&1 && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      This box is the office gateway. A WireGuard tunnel (wg0, managed by
      wg-quick@wg0 from /etc/wireguard/wg0.conf) connects it to the datacenter,
      where the application servers live on 10.87.0.0/24.

      The tunnel looks healthy:

        wg show
        ping -c2 10.86.0.2          # the datacenter end of the tunnel

      The servers behind it are not reachable:

        curl -s -m 5 http://10.87.0.10:8080/

      Make 10.87.0.10:8080 reachable from this box through the tunnel, and keep
      it that way after wg-quick@wg0 restarts.

      The datacenter end is another team's: read it with ip netns exec dc wg
      show, do not change it. Traffic to the datacenter must stay inside the
      tunnel — the underlay (to-dc) stands in for the internet. And the tunnel
      is for the datacenter, not for everything: this box's other traffic,
      to the lab network and elsewhere, must not be pulled into it.
      Q

      echo "scenario ready — handshake fresh, servers unreachable"
      wg show wg0 | sed 's/^/  /'

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      # ---- the far end is not ours -------------------------------------
      dc_allowed=$(ip netns exec dc wg show wg0 allowed-ips 2>/dev/null | awk '{$1=""; print}' | xargs || true)
      if [ "$dc_allowed" != "10.86.0.1/32" ]; then
        echo "not yet: the datacenter's tunnel config has been changed"
        echo "         (its allowed-ips for this office are now: ${dc_allowed:-none})."
        echo "         That end belongs to the datacenter team. Put it back; the fault"
        echo "         is on this side."
        exit 1
      fi

      if ! systemctl is-active --quiet wg-quick@wg0.service; then
        echo "not yet: wg-quick@wg0 is not running.  journalctl -u wg-quick@wg0 -n 20"
        exit 1
      fi

      # ---- the tunnel is not a default route ---------------------------
      allowed=$(wg show wg0 allowed-ips 2>/dev/null | awk '{$1=""; print}' | xargs || true)
      case " $allowed " in
        *" 0.0.0.0/0 "*)
          echo "not yet: the datacenter peer is allowed 0.0.0.0/0."
          echo "         That works, and wg-quick takes it as an instruction to send"
          echo "         *all* of this box's traffic into the tunnel. Allow what lives"
          echo "         behind that peer, and nothing else."
          exit 1
          ;;
      esac
      if ! ip route get 172.31.0.11 2>/dev/null | grep -q 'dev eth0'; then
        echo "not yet: traffic to the lab network (172.31.0.11) no longer leaves by eth0:"
        echo "           $(ip route get 172.31.0.11 2>&1 | head -1)"
        echo "         Only the datacenter's networks belong in the tunnel."
        exit 1
      fi

      # ---- the path ----------------------------------------------------
      sel=$(ip route get 10.87.0.10 2>&1 | head -1)
      if ! printf '%s' "$sel" | grep -q 'dev wg0'; then
        echo "not yet: traffic to 10.87.0.10 does not go into the tunnel:"
        echo "           $sel"
        if printf '%s' "$sel" | grep -q 'to-dc'; then
          echo "         That is the underlay — the internet, in this lab. It reaches the"
          echo "         datacenter, in clear text. The tunnel is the point."
        else
          echo "         Nothing routes 10.87.0.0/24 into wg0. Where do the routes wg0 does"
          echo "         have come from?  ip route show dev wg0"
        fi
        exit 1
      fi

      page=$(curl -s -m 5 http://10.87.0.10:8080/ 2>/dev/null || true)
      if ! printf '%s' "$page" | grep -q dc-app-answers-2026; then
        echo "not yet: the route to 10.87.0.10 points into wg0, and the server still"
        echo "         does not answer. Ask WireGuard rather than the routing table:"
        echo "           ping -c1 10.87.0.10"
        echo "           wg show wg0 allowed-ips"
        echo "         A route gets a packet to wg0. Which peer it is encrypted for, if"
        echo "         any, is decided by something else."
        exit 1
      fi

      # ---- and after wg-quick restarts ---------------------------------
      conf_allowed=$(sed -n 's/^[[:space:]]*AllowedIPs[[:space:]]*=[[:space:]]*//p' /etc/wireguard/wg0.conf 2>/dev/null | tr ',' ' ' | xargs || true)
      case " $conf_allowed " in
        *" 10.87.0.0/24 "*) ;;
        *)
          echo "not yet: it works now, and /etc/wireguard/wg0.conf still allows only:"
          echo "           ${conf_allowed:-nothing}"
          echo "         wg-quick@wg0 rebuilds wg0 from that file on restart; a change made"
          echo "         with wg set lives only in the running interface."
          exit 1
          ;;
      esac

      echo "PASS — 10.87.0.10 is reached through wg0, the datacenter peer is allowed"
      echo "       exactly what lives behind it, and the config file says so."
