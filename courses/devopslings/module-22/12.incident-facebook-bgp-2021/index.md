---
kind: lesson
title: "Replay: Facebook, October 2021"
description: |
  A maintenance command withdrew more than it meant to, the servers that
  announce the address withdrew themselves as designed, and the tool to
  undo it was reached through that address. Replay it on the load
  balancers, then build the way in that does not depend on the thing that
  broke, and prove it while www is gone.
name: incident-facebook-bgp-2021
slug: incident-facebook-bgp-2021
createdAt: "2026-10-17"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      cat > /ha/haproxy.cfg <<'CFG'
      # Shared by lb1 and lb2. Saved changes are picked up within a second; a config
      # HAProxy rejects is logged to /ha/lb1/log and /ha/lb2/log and not applied.
      global
          # The operators' runtime API, published on www so every tool needs one
          # address. transparent lets the node without the VIP bind it too.
          stats socket ipv4@172.29.22.100:9999 level admin transparent

      frontend www
          bind :80
          default_backend app

      # keepalived asks this before holding www: a node with no server left to
      # send traffic to gives the address up.
      frontend announce
          bind 127.0.0.1:8405
          monitor-uri /announce
          monitor fail if { nbsrv(app) lt 1 }

      backend app
          balance roundrobin
          option httpchk GET /health
          server web1 172.29.22.21:8080 check inter 1s fall 2 rise 2
          server web2 172.29.22.22:8080 check inter 1s fall 2 rise 2
      CFG
      for n in lb1 lb2; do
        case $n in lb1) state=MASTER prio=150 ;; lb2) state=BACKUP prio=100 ;; esac
        mkdir -p "/ha/$n"
        cat > "/ha/$n/keepalived.conf" <<KA
      # $n's VRRP config. Saved changes restart keepalived on $n.
      global_defs {
          script_user root
          enable_script_security
      }

      vrrp_script announce {
          script "/usr/bin/curl -fs -o /dev/null --max-time 1 http://127.0.0.1:8405/announce"
          interval 1
          fall 2
          rise 2
      }

      vrrp_instance www {
          state $state
          interface eth0
          virtual_router_id 22
          priority $prio
          advert_int 1
          virtual_ipaddress {
              172.29.22.100/24
          }
          track_script {
              announce
          }
      }
      KA
      done
      holder() {
        local n
        for n in lb1 lb2; do
          docker exec "devopslings-ha-$n" ip -br addr show eth0 2>/dev/null | grep -q 172.29.22.100 && echo "$n"
        done
        true
      }
      api() { timeout 3 bash -c 'exec 3<>/dev/tcp/www/9999 && echo "$1" >&3 && cat <&3' _ "$1" 2>/dev/null; }
      for _ in $(seq 60); do
        [ "$(holder)" = lb1 ] && api "show info" | grep -q '^Name: HAProxy' && curl -fsS --max-time 1 http://www/ >/dev/null 2>&1 && break
        sleep 0.5
      done

      # 14:02 — the drain. Meant for web1; the server pattern it was given was
      # empty, so it matched both.
      api "disable server app/web1; disable server app/web2" >/dev/null || true
      for _ in $(seq 40); do [ "$(holder)" = lb2 ] && break; sleep 0.5; done
      # 14:03 — the drain tool checks its work through www, now answered by lb2.
      for _ in $(seq 20); do api "show info" | grep -q '^Name: HAProxy' && break; sleep 0.5; done
      api "disable server app/web1; disable server app/web2" >/dev/null || true
      for _ in $(seq 40); do [ -z "$(holder)" ] && break; sleep 0.5; done

      mkdir -p /ha/oob
      cat > /ha/oob/INCIDENT.txt <<'TXT'
      14:02  maintenance: drain web1 for a kernel update. The drain tool sends
             "disable server" to www:9999 for every server matching its pattern.
             The pattern was empty. It matched web1 and web2.
      14:02  lb1 has no server left. Its announce check fails, and keepalived
             gives up www, as designed. lb2 takes www over.
      14:03  The tool verifies through www, now lb2, sees both servers enabled,
             and drains again. lb2 gives up www. Nobody holds it.
      14:04  Rollback: "enable server" to www:9999. No route to host.
      TXT
      cat > /ha/answers/facebook-2021.txt <<'TXT'
      # The rollback the operators reached for at 14:04:
      #   exec 3<>/dev/tcp/www/9999; echo "enable server app/web1; enable server app/web2" >&3
      # For each item: yes if that rollback could not work without it, no if it
      # could.
      front_network: ?
      the_vip: ?
      haproxy_on_the_vip_holder: ?
      an_enabled_server: ?
      pg1: ?
      etcd: ?
      TXT
      cat > /ha/oob/console.env <<'ENV'
      # The way in when www is gone. The grader starts a console from the ops
      # image with no Docker socket and no /ha, attached only to NETWORK, and
      # runs /ha/oob/rollback.sh there with these three variables set.
      #
      # NETWORK: a Docker network. LB1, LB2: each node's runtime API on it,
      # as address:port.
      NETWORK=
      LB1=
      LB2=
      ENV
      cat > /ha/oob/rollback.sh <<'SH'
      #!/bin/bash
      # Runs in the console, with NETWORK, LB1 and LB2 from console.env set.
      # Afterwards web1 and web2 are enabled on both load balancers.
      set -eu
      echo "rollback: not written yet" >&2
      exit 1
      SH
      chmod +x /ha/oob/rollback.sh

      echo "scenario ready — www is gone, and so is the way to fix it:"
      echo
      for n in lb1 lb2; do
        printf '  %s  www=%s  ' "$n" "$(docker exec "devopslings-ha-$n" ip -br addr show eth0 | grep -q 172.29.22.100 && echo held || echo released)"
        docker exec "devopslings-ha-$n" lbctl stat | grep '^app,web' | cut -d, -f2,3 | paste -sd' ' -
      done
      echo "  curl http://www/  $(curl -s --max-time 3 -o /dev/null -w '%{http_code}' http://www/ || true)"
      echo
      echo "  what happened:        /ha/oob/INCIDENT.txt"
      echo "  your reconstruction:  /ha/answers/facebook-2021.txt"
      echo "  your way in:          /ha/oob/console.env and /ha/oob/rollback.sh"
      echo "  the data-center door: docker exec devopslings-ha-lb1 ...   (works today; see the lesson)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      console=devopslings-ha-console
      both="enable server app/web1; enable server app/web2"
      sock() { docker exec "devopslings-ha-$1" sh -c "echo '$2' | socat stdio /run/haproxy.sock" >/dev/null 2>&1 || true; }
      staged=""
      trap 'docker rm -f "$console" >/dev/null 2>&1; if [ -n "$staged" ]; then sock lb1 "$both"; sock lb2 "$both"; fi; true' EXIT
      docker rm -f "$console" >/dev/null 2>&1 || true

      ans() { awk -F: -v k="$1" '$1 ~ "^[[:space:]]*" k "[[:space:]]*$" { print tolower($2); exit }' /ha/answers/facebook-2021.txt 2>/dev/null | tr -d ' \t' || true; }
      for row in "front_network yes" "the_vip yes" "haproxy_on_the_vip_holder yes" "an_enabled_server yes" "pg1 no" "etcd no"; do
        set -- $row
        a=$(ans "$1")
        case $a in yes|no) ;; *)
          echo "not yet: $1 in /ha/answers/facebook-2021.txt is '${a:-missing}'; answer yes or no."
          exit 1 ;;
        esac
        [ "$a" = "$2" ] && continue
        echo "not yet: $1: $a."
        case $1 in
          front_network) echo "         ops reaches www over the front network. Without it the rollback has no path at all." ;;
          the_vip) echo "         The runtime API is bound to 172.29.22.100 only. When nobody holds that address, nothing listens." ;;
          haproxy_on_the_vip_holder) printf '%s\n' "         The address leads to a port, and the port is HAProxy's runtime API. A node holding www with" \
                                          "         HAProxy dead answers nothing on 9999." ;;
          an_enabled_server) printf '%s\n' "         keepalived holds www only while /announce says the node has a server left. The rollback" \
                                  "         enables servers, and it needs a node with an enabled server to reach. That is the loop." ;;
          pg1|etcd) printf '%s\n' "         Follow the rollback's path: ops, the front network, www, HAProxy. $1 is not on it, and the" \
                         "         announce check asks HAProxy about servers being enabled and up, not about $1." ;;
        esac
        exit 1
      done
      echo "reconstruction: the rollback needed the front network, the VIP, HAProxy on its holder, and an enabled server"

      NETWORK=$(sed -n 's/^[[:space:]]*NETWORK[[:space:]]*=[[:space:]]*//p' /ha/oob/console.env 2>/dev/null | tail -1 | tr -d '"'"'"' ')
      LB1=$(sed -n 's/^[[:space:]]*LB1[[:space:]]*=[[:space:]]*//p' /ha/oob/console.env 2>/dev/null | tail -1 | tr -d '"'"'"' ')
      LB2=$(sed -n 's/^[[:space:]]*LB2[[:space:]]*=[[:space:]]*//p' /ha/oob/console.env 2>/dev/null | tail -1 | tr -d '"'"'"' ')
      if [ -z "$NETWORK" ] || [ -z "$LB1" ] || [ -z "$LB2" ]; then
        echo "not yet: /ha/oob/console.env needs NETWORK, LB1 and LB2."
        exit 1
      fi
      case $NETWORK in *_front|*_back|front|back|host|none)
        echo "not yet: NETWORK=$NETWORK. front and back carry the shop's own traffic, and the next change that"
        echo "         takes them down takes the way in with them. The way in needs a network of its own."
        exit 1 ;;
      esac
      if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
        echo "not yet: there is no Docker network called $NETWORK (docker network ls)."
        exit 1
      fi
      for n in lb1 lb2; do
        if ! docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "devopslings-ha-$n" | tr ' ' '\n' | grep -qxF "$NETWORK"; then
          echo "not yet: $n is not attached to $NETWORK, so nothing on that network can reach it."
          exit 1
        fi
      done
      if [ ! -s /ha/oob/rollback.sh ]; then
        echo "not yet: /ha/oob/rollback.sh is missing or empty."
        exit 1
      fi

      # The 14:02 drain again, on both nodes, through the grader's own door.
      staged=1
      sock lb1 "disable server app/web1; disable server app/web2"
      sock lb2 "disable server app/web1; disable server app/web2"
      gone=""
      for _ in $(seq 20); do
        curl -fsS --max-time 1 -o /dev/null http://www/ 2>/dev/null || { gone=1; break; }
        sleep 0.5
      done
      if [ -z "$gone" ]; then
        echo "not yet: with web1 and web2 drained on both load balancers, www still answers. Something other"
        echo "         than lb1 and lb2 is serving it; put the scenario back with a reset."
        exit 1
      fi
      echo "drained on both nodes: www is down"

      img=$(docker inspect -f '{{.Image}}' devopslings-ha-ops)
      docker run -d --name "$console" --network "$NETWORK" --entrypoint sleep "$img" 300 >/dev/null
      docker cp /ha/oob/rollback.sh "$console:/root/rollback.sh" >/dev/null
      # Each node's API, asked from the console before the rollback runs.
      for row in "lb1 $LB1" "lb2 $LB2"; do
        set -- $row
        if ! docker exec "$console" timeout 3 bash -c 'h=${1%:*}; p=${1##*:}; exec 3<>"/dev/tcp/$h/$p" && echo "show info" >&3 && cat <&3' _ "$2" 2>/dev/null | grep -q '^Name: HAProxy'; then
          ip=$(docker inspect -f "{{(index .NetworkSettings.Networks \"$NETWORK\").IPAddress}}" "devopslings-ha-$1" 2>/dev/null || true)
          echo "not yet: from a console on $NETWORK, ${1^^}=$2 does not answer as HAProxy's runtime API."
          if [ -n "$ip" ] && [ "${2%:*}" != "$ip" ] && [ "${2%:*}" != "$1" ]; then
            echo "         $1's address on $NETWORK is $ip."
          elif docker exec "$console" ping -c1 -W1 "${2%:*}" >/dev/null 2>&1; then
            echo "         $1 answers ping there, but nothing listens on port ${2##*:}: the scenario binds the API"
            echo "         to the VIP only, and HAProxy listens only where its config says."
          fi
          exit 1
        fi
      done

      rc=0
      docker exec -e NETWORK="$NETWORK" -e LB1="$LB1" -e LB2="$LB2" "$console" timeout 60 bash /root/rollback.sh > /tmp/rollback.log 2>&1 || rc=$?
      if [ "$rc" -ne 0 ]; then
        echo "not yet: /ha/oob/rollback.sh exited $rc in the console. Its last lines:"
        tail -5 /tmp/rollback.log | sed 's/^/         | /'
        if grep -q 'docker daemon\|docker.sock' /tmp/rollback.log; then
          echo "         The console has no Docker socket. docker is the door into the data center: it is the"
          echo "         slow, last way in, and not one an operator at home has."
        fi
        exit 1
      fi
      for n in lb1 lb2; do
        m=$(docker exec "devopslings-ha-$n" lbctl stat 2>/dev/null | awk -F, '$1 == "app" && $3 ~ /MAINT/ { print $2 }' | paste -sd' ' - || true)
        if [ -n "$m" ]; then
          echo "not yet: after rollback.sh, $n still has $m in maintenance. Each load balancer was drained on its"
          echo "         own, and each has to be told on its own."
          exit 1
        fi
      done
      up=""
      for _ in $(seq 30); do
        curl -fsS --max-time 1 -o /dev/null http://www/ 2>/dev/null && { up=1; break; }
        sleep 0.5
      done
      if [ -z "$up" ]; then
        echo "not yet: both load balancers have web1 and web2 enabled, but www did not come back within 15s."
        exit 1
      fi
      staged=""
      echo "rollback from a console on $NETWORK, with www gone: both nodes re-enabled, www is back"
      echo
      echo "PASS — the way in did not depend on the thing that broke."
