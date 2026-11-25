---
kind: lesson
title: "one upstream is slow for one client, sometimes"
description: |
  The payments client calls two upstreams. Calls to one of them are
  intermittently slow — a second here, three there — and everything else is
  fine. ping says the RTT is normal. Retransmits are what turn a lost packet
  into a stall, and tcpretrans.bt names every one with both ends of the
  connection. The work is finding the peer, then the loss on its path.
name: tcp-retransmits
slug: tcp-retransmits
createdAt: "2026-11-23"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      set -e

      # ---- clean slate ---------------------------------------------------
      systemctl stop payments-client.service upstream@ledger-api.service \
        upstream@fx-rates.service 2>/dev/null || true
      systemctl reset-failed payments-client.service 'upstream@*' 2>/dev/null || true
      for ns in ledger-api fx-rates; do ip netns del "$ns" 2>/dev/null || true; done
      ip link del pay-ledger 2>/dev/null || true
      ip link del pay-fx 2>/dev/null || true
      rm -rf /opt/upstream /usr/local/bin/payments-client /root/answers/retrans.md \
             /etc/systemd/system/payments-client.service \
             /etc/systemd/system/upstream@.service
      install -d /root/answers /opt/upstream
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

      # ---- two upstreams, each in its own network namespace ---------------
      # ledger-api 10.81.1.2 via pay-ledger, fx-rates 10.81.2.2 via pay-fx.
      i=1
      for ns in ledger-api fx-rates; do
        host=$([ "$ns" = ledger-api ] && echo pay-ledger || echo pay-fx)
        ip netns add "$ns"
        ip link add "$host" type veth peer name eth0 netns "$ns"
        ip addr add "10.81.$i.1/24" dev "$host"
        ip link set "$host" up
        ip -n "$ns" addr add "10.81.$i.2/24" dev eth0
        ip -n "$ns" link set eth0 up
        ip -n "$ns" link set lo up
        i=$((i + 1))
      done
      head -c 262144 /dev/urandom > /opt/upstream/quote.bin
      cat > /etc/systemd/system/upstream@.service <<'U'
      [Unit]
      Description=Upstream %i

      [Service]
      NetworkNamespacePath=/run/netns/%i
      WorkingDirectory=/opt/upstream
      ExecStart=/usr/bin/python3 -m http.server 8080
      U

      # The fault: 3% loss on fx-rates' side of its link, where the client's
      # host cannot see it.
      ip netns exec fx-rates tc qdisc add dev eth0 root netem loss 3%

      # ---- the client ------------------------------------------------------
      cat > /usr/local/bin/payments-client <<'SH'
      #!/bin/sh
      while :; do
        curl -s -o /dev/null http://10.81.1.2:8080/quote.bin
        curl -s -o /dev/null http://10.81.2.2:8080/quote.bin
        sleep 0.3
      done
      SH
      chmod 0755 /usr/local/bin/payments-client
      cat > /etc/systemd/system/payments-client.service <<'U'
      [Unit]
      Description=Payments client
      After=upstream@ledger-api.service upstream@fx-rates.service

      [Service]
      ExecStart=/usr/local/bin/payments-client
      U
      systemctl daemon-reload
      systemctl start upstream@ledger-api.service upstream@fx-rates.service
      for ip in 10.81.1.2 10.81.2.2; do
        for _ in $(seq 40); do
          curl -s -o /dev/null --max-time 2 "http://$ip:8080/" && break
          sleep 0.25
        done
      done
      systemctl start payments-client.service

      cat > /root/questions.txt <<'Q'
      payments-client calls ledger-api (10.81.1.2) and fx-rates (10.81.2.2).
      Calls to one of them stall now and then; ping looks fine.

      Find which peer the retransmits are with, find what is losing packets on
      that path, and remove it. Then write /root/answers/retrans.md:

        peer: <address of the upstream the retransmits are with>
        cause: <what was dropping packets, and where>
      Q

      echo "scenario ready — payments-client sees occasional stalls to one upstream"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e
      ans=/root/answers/retrans.md

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty:  peer: <address>  cause: <...>"
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | head -n 1; }
      peer=$(field peer)
      if printf '%s' "$peer" | grep -Eq '10\.81\.1\.2\b|ledger'; then
        echo "not yet: peer says ledger-api. Its calls are fine. tcpretrans.bt prints"
        echo "         both addresses of each retransmitted segment — run it for ten"
        echo "         seconds and see which upstream every line names."
        exit 1
      fi
      if ! printf '%s' "$peer" | grep -Eq '10\.81\.2\.2\b|fx-rates'; then
        echo "not yet: peer says '${peer:-nothing}'. Name the upstream the retransmits"
        echo "         are with, by address."
        exit 1
      fi
      cause=$(field cause)
      if ! printf '%s' "$cause" | grep -Eq '\b(netem|qdisc|tc)\b'; then
        echo "not yet: cause says '${cause:-nothing}'. That is the symptom; say what was"
        echo "         dropping packets — the qdisc — and where it sat."
        exit 1
      fi
      if ! printf '%s' "$cause" | grep -Eq '\b(fx-rates|namespace|netns|eth0)\b'; then
        echo "not yet: cause says '$cause' but not where. Name the interface and the"
        echo "         namespace the qdisc was on."
        exit 1
      fi

      # ---- the path still works, and the loss is gone --------------------
      if ! ip netns list | grep -q '^fx-rates\b'; then
        echo "not yet: the fx-rates namespace is gone. The upstream has to stay; the"
        echo "         loss on its path is what goes."
        exit 1
      fi
      for spot in "ip netns exec fx-rates tc qdisc show dev eth0" "tc qdisc show dev pay-fx"; do
        q=$($spot 2>/dev/null || true)
        if printf '%s' "$q" | grep -q netem; then
          echo "not yet: '$spot' still shows a netem qdisc:"
          printf '%s\n' "$q" | grep netem | sed 's/^/         /'
          echo "         Any loss setting on this path — even a smaller one — still"
          echo "         drops packets. Delete the qdisc."
          exit 1
        fi
      done

      retrans() {
        { nstat -az TcpRetransSegs; ip netns exec fx-rates nstat -az TcpRetransSegs; } \
          | awk '/TcpRetransSegs/ {s += $2} END {print s + 0}'
      }
      before=$(retrans)
      fails=0
      for _ in $(seq 40); do
        curl -s -o /dev/null --max-time 5 http://10.81.2.2:8080/quote.bin || fails=$((fails + 1))
      done
      after=$(retrans)
      if [ "$fails" -gt 0 ]; then
        echo "not yet: $fails of 40 calls to fx-rates failed. The upstream has to"
        echo "         answer; systemctl status upstream@fx-rates says why it does not."
        exit 1
      fi
      if [ "$after" -gt "$before" ]; then
        echo "not yet: 40 calls to fx-rates retransmitted $((after - before)) segments"
        echo "         (TcpRetransSegs). Something on the path still loses packets."
        exit 1
      fi

      echo "PASS — the retransmits were with fx-rates, the netem loss on its link is"
      echo "       gone, and 40 calls to it retransmitted nothing."
