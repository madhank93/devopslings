---
kind: lesson
title: "one branch is in the routing table and the other never arrives"
description: |
  The core router runs OSPF to two branch routers over identical circuits, with
  configs that differ by one stanza. Branch 2's subnet is learned and reachable.
  Branch 1's never appears. Both interfaces are up, both routers are running
  OSPF on the link, and hellos are crossing it in both directions — and each
  side throws the other's away.
name: ospf-neighbour-never-forms
slug: ospf-neighbour-never-forms
createdAt: "2026-10-13"

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
      systemctl stop frr.service 'frr@*.service' branch-web@edge1.service branch-web@edge2.service 2>/dev/null || true
      systemctl reset-failed 'frr@*.service' frr.service 2>/dev/null || true
      for l in to-edge1 to-edge2; do ip link del "$l" 2>/dev/null || true; done
      for ns in edge1 edge2; do ip netns del "$ns" 2>/dev/null || true; done
      ip route flush proto ospf 2>/dev/null || true
      ip route del 10.81.1.0/24 2>/dev/null || true
      rm -rf /etc/frr/edge1 /etc/frr/edge2 /etc/systemd/system/frr@.service.d \
             /etc/systemd/system/branch-web@.service /srv/branch

      # ---- the topology ------------------------------------------------
      #
      #             to-edge1 10.80.1.1/30 ── edge1 10.80.1.2 ── branch 10.81.1.0/24
      #   core (this box)
      #             to-edge2 10.80.2.1/30 ── edge2 10.80.2.2 ── branch 10.81.2.0/24
      #
      # Each branch router is a network namespace running its own FRR instance
      # (frr@edge1, frr@edge2). They are the branch team's routers; this box is
      # the core and is yours.
      mk_edge() {
        n=$1 i=$2
        ip netns add "edge$n"
        ip link add "to-edge$n" type veth peer name core0 netns "edge$n"
        ip addr add "10.80.$n.1/30" dev "to-edge$n"
        ip link set "to-edge$n" up
        ip netns exec "edge$n" sh -c "
          ip link set lo up
          ip addr add 10.80.$n.2/30 dev core0
          ip link set core0 up
          ip link add branch0 type dummy
          ip addr add 10.81.$n.1/24 dev branch0
          ip link set branch0 up
          sysctl -qw net.ipv4.ip_forward=1
        "
        install -d -o frr -g frr -m 755 "/etc/frr/edge$n"
        sed 's/^ospfd=no/ospfd=yes/' /usr/share/frr-lesson-daemons > "/etc/frr/edge$n/daemons"
        cat > "/etc/frr/edge$n/frr.conf" <<CONF
      frr defaults traditional
      hostname edge$n
      log syslog informational
      !
      interface core0
       ip ospf network point-to-point
      !
      router ospf
       ospf router-id 10.80.255.$i
       network 10.80.$n.0/30 area 0
       network 10.81.$n.0/24 area 0
      !
      CONF
        cp /etc/frr/vtysh.conf "/etc/frr/edge$n/vtysh.conf"
        chown frr:frr "/etc/frr/edge$n/daemons" "/etc/frr/edge$n/frr.conf" "/etc/frr/edge$n/vtysh.conf"
        chmod 640 "/etc/frr/edge$n/frr.conf"
        install -d "/srv/branch/edge$n"
        echo "branch$n-answers-2026" > "/srv/branch/edge$n/index.html"
      }

      # A pristine daemons file to derive every instance's from, so a rerun
      # never inherits a previous lesson's daemon list.
      if [ ! -f /usr/share/frr-lesson-daemons ]; then
        sed -E 's/^(bgpd|ospfd)=yes/\1=no/' /etc/frr/daemons > /usr/share/frr-lesson-daemons
      fi
      mk_edge 1 2
      mk_edge 2 3

      # frr@NAME runs FRR with its config under /etc/frr/NAME. The drop-in puts
      # each instance in the network namespace of the same name.
      install -d /etc/systemd/system/frr@.service.d
      printf '[Service]\nNetworkNamespacePath=/run/netns/%%i\n' > /etc/systemd/system/frr@.service.d/netns.conf

      printf '[Unit]\nDescription=branch web service in %%i\nAfter=network.target\n\n[Service]\nNetworkNamespacePath=/run/netns/%%i\nExecStart=/usr/bin/python3 -m http.server 8080 --bind 0.0.0.0 --directory /srv/branch/%%i\nRestart=always\n' \
        > /etc/systemd/system/branch-web@.service

      # ---- the core ----------------------------------------------------
      sed 's/^ospfd=no/ospfd=yes/' /usr/share/frr-lesson-daemons > /etc/frr/daemons
      cat > /etc/frr/frr.conf <<'CONF'
      frr defaults traditional
      hostname core
      log syslog informational
      !
      interface to-edge1
       ip ospf network point-to-point
       ! CHG-0577: fast failure detection on the branch-1 circuit.
       ! The CPE there cannot run BFD, so shorten the OSPF timers instead.
       ip ospf hello-interval 1
       ip ospf dead-interval 4
      !
      interface to-edge2
       ip ospf network point-to-point
      !
      router ospf
       ospf router-id 10.80.255.1
       network 10.80.1.0/30 area 0
       network 10.80.2.0/30 area 0
      !
      CONF
      chown frr:frr /etc/frr/daemons /etc/frr/frr.conf
      chmod 640 /etc/frr/frr.conf

      systemctl daemon-reload
      systemctl start frr@edge1.service frr@edge2.service frr.service
      systemctl start branch-web@edge1.service branch-web@edge2.service

      for _ in $(seq 1 60); do
        ip route show 10.81.2.0/24 2>/dev/null | grep -q 'proto ospf' && break
        sleep 1
      done

      cat > /root/questions.txt <<'Q'
      This box is the core router. It runs OSPF (FRR, frr.service, config in
      /etc/frr/frr.conf) to two branch routers over two identical circuits:

        to-edge1 10.80.1.1/30  ->  edge1  ->  branch 1, 10.81.1.0/24
        to-edge2 10.80.2.1/30  ->  edge2  ->  branch 2, 10.81.2.0/24

      Branch 2 is fine:

        curl -s http://10.81.2.1:8080/

      Branch 1 is unreachable, and 10.81.1.0/24 is not in the routing table:

        curl -s -m 5 http://10.81.1.1:8080/
        ip route show proto ospf

      Both circuits are up. Both branch routers run OSPF on their side of the
      link. The routing daemon on this box is talking to them:

        vtysh -c 'show ip ospf neighbor'
        vtysh -N edge1 -c 'show ip ospf neighbor'     # the branch router's view

      Make branch 1's subnet reachable from this box, learned through OSPF the
      way branch 2's is, and make it survive a restart of frr.service.

      The branch routers belong to the branch team: read them all you like,
      change only this box. Branch 2 must keep working.
      Q

      echo "scenario ready — branch 2 learned, branch 1 missing"
      ip route show proto ospf | sed 's/^/  /'

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      json_field() {
        python3 -c 'import json,sys
      d=json.load(sys.stdin); path=sys.argv[1].split(".")
      for p in path:
          d=d.get(p, {}) if isinstance(d, dict) else {}
      print(d if d != {} else "")' "$1"
      }

      # ---- the branch router is not yours -------------------------------
      ej=$(vtysh -N edge1 -c 'show ip ospf interface core0 json' 2>/dev/null || true)
      e_hello=$(printf '%s' "$ej" | json_field interfaces.core0.timerMsecs 2>/dev/null || true)
      e_dead=$(printf '%s' "$ej" | json_field interfaces.core0.timerDeadSecs 2>/dev/null || true)
      if [ "$e_hello" != "10000" ] || [ "$e_dead" != "40" ]; then
        echo "not yet: edge1's OSPF timers on core0 are no longer 10s hello / 40s dead"
        echo "         (now hello=${e_hello:-?}ms dead=${e_dead:-?}s)."
        echo "         That router belongs to the branch team, and matching it to the core"
        echo "         puts a one-second hello on a CPE nobody asked. Put it back and"
        echo "         change this box."
        exit 1
      fi

      if ! systemctl is-active --quiet frr.service; then
        echo "not yet: frr.service is not running on this box. Nothing here is"
        echo "         learning any routes.  journalctl -u frr.service -n 30"
        exit 1
      fi

      # ---- the working branch stays working ----------------------------
      if ! vtysh -c 'show ip ospf neighbor' 2>/dev/null | grep -q '^10\.80\.255\.3 .*Full'; then
        echo "not yet: the adjacency to edge2 (10.80.255.3) is not Full any more."
        echo "         Branch 2 worked when you started."
        exit 1
      fi
      if ! curl -s -m 5 http://10.81.2.1:8080/ 2>/dev/null | grep -q branch2-answers-2026; then
        echo "not yet: branch 2 (10.81.2.1) is no longer reachable from this box."
        exit 1
      fi

      # ---- the adjacency -----------------------------------------------
      #
      # A just-fixed link takes up to one hello interval to come up, so allow
      # a little time before calling it.
      full=0
      for _ in $(seq 1 15); do
        if vtysh -c 'show ip ospf neighbor' 2>/dev/null | grep -q '^10\.80\.255\.2 .*Full'; then
          full=1; break
        fi
        sleep 1
      done
      if [ "$full" -ne 1 ]; then
        echo "not yet: there is no Full OSPF adjacency to edge1 (10.80.255.2)."
        echo "         Hellos are crossing to-edge1 in both directions:"
        echo "           tcpdump -ni to-edge1 proto ospf"
        echo "         and neither router lists the other as a neighbour. A router"
        echo "         discards a hello it disagrees with. Compare what each side"
        echo "         puts in its hellos:"
        echo "           vtysh -c 'show ip ospf interface to-edge1'"
        echo "           vtysh -N edge1 -c 'show ip ospf interface core0'"
        exit 1
      fi

      # ---- the route, and how it got there ------------------------------
      # Full is the end of the handshake; the route follows once the link-state
      # databases are exchanged and SPF runs.
      r=""
      for _ in $(seq 1 20); do
        r=$(ip route show 10.81.1.0/24 2>/dev/null)
        printf '%s' "$r" | grep -q 'proto ospf' && break
        sleep 1
      done
      if [ -z "$r" ]; then
        echo "not yet: edge1 is a Full neighbour and 10.81.1.0/24 is still not in the"
        echo "         routing table after 20 seconds. Is edge1 advertising it?"
        echo "           vtysh -c 'show ip ospf database'"
        echo "           vtysh -c 'show ip ospf route'"
        exit 1
      fi
      if ! printf '%s' "$r" | grep -q 'proto ospf'; then
        echo "not yet: 10.81.1.0/24 is in the table, and OSPF did not put it there:"
        echo "           $r"
        echo "         A static route reaches branch 1 today and stays put the day that"
        echo "         circuit fails, which is the day you needed the routing protocol."
        exit 1
      fi
      if ! curl -s -m 5 http://10.81.1.1:8080/ 2>/dev/null | grep -q branch1-answers-2026; then
        echo "not yet: 10.81.1.0/24 is learned through OSPF and branch 1's service at"
        echo "         10.81.1.1:8080 still does not answer."
        exit 1
      fi

      # ---- and it survives a restart -----------------------------------
      #
      # The running config is what is in effect; /etc/frr/frr.conf is what
      # frr.service loads on its next start. Both must agree with edge1.
      saved=$(awk '/^interface to-edge1/{f=1;next} /^[^ ]/{f=0} f' /etc/frr/frr.conf 2>/dev/null || true)
      s_hello=$(printf '%s\n' "$saved" | sed -n 's/^[[:space:]]*ip ospf hello-interval[[:space:]]*\([0-9]*\).*/\1/p' | tail -1)
      s_dead=$(printf '%s\n' "$saved" | sed -n 's/^[[:space:]]*ip ospf dead-interval[[:space:]]*\([0-9]*\).*/\1/p' | tail -1)
      : "${s_hello:=10}" "${s_dead:=40}"
      if [ "$s_hello" != "10" ] || [ "$s_dead" != "40" ]; then
        echo "not yet: the adjacency is up, and /etc/frr/frr.conf still gives to-edge1"
        echo "         hello=${s_hello}s dead=${s_dead}s, where edge1 uses 10s and 40s."
        echo "         That file is what frr.service loads on restart. A change made in"
        echo "         vtysh lives in the running daemon until it is written out."
        exit 1
      fi

      echo "PASS — edge1 is a Full OSPF neighbour, 10.81.1.0/24 is learned through it,"
      echo "       branch 2 is untouched, and the saved config agrees with what is running."
