---
kind: lesson
title: "Certificate rotation behind a VIP"
description: |
  The certificate for www was renewed this morning, and the node holding the
  address serves the new one. The other node still has the old one loaded,
  and it takes over the address the next time anything fails. Rotate it on
  every node, under load, without one failed handshake.
name: cert-rotation-behind-a-vip
slug: cert-rotation-behind-a-vip
createdAt: "2026-10-16"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      mkdir -p /ha/certs
      # The lab's CA. Its key stays in ops' home, where the grader issues
      # renewals from.
      openssl req -x509 -newkey rsa:2048 -nodes -days 60 -subj "/CN=devopslings HA lab CA" \
        -keyout /root/.cert-rotation-ca.key -out /ha/certs/ca.pem 2>/dev/null
      cat > /root/.cert-rotation-issue <<'SH'
      # issue <out.pem> — a new key and a certificate for www, signed by the lab CA.
      set -eu
      d=$(mktemp -d)
      openssl req -newkey rsa:2048 -nodes -subj "/CN=www" -keyout "$d/key" -out "$d/csr" 2>/dev/null
      printf 'subjectAltName=DNS:www,IP:172.29.22.100,IP:172.29.22.11,IP:172.29.22.12\n' > "$d/ext"
      openssl x509 -req -in "$d/csr" -CA /ha/certs/ca.pem -CAkey /root/.cert-rotation-ca.key \
        -set_serial "0x$(openssl rand -hex 8)" -days 30 -extfile "$d/ext" -out "$d/crt" 2>/dev/null
      cat "$d/crt" "$d/key" > "$d/pem"
      mv "$d/pem" "$1"
      rm -rf "$d"
      SH
      bash /root/.cert-rotation-issue /ha/certs/www.pem
      cat > /ha/haproxy.cfg <<'CFG'
      # Shared by lb1 and lb2. Saved changes are picked up within a second; a config
      # HAProxy rejects is logged to /ha/lb1/log and /ha/lb2/log and not applied.
      frontend www
          bind :80
          bind :443 ssl crt /ha/certs/www.pem
          default_backend app

      backend app
          balance roundrobin
          option httpchk GET /health
          server web1 172.29.22.21:8080 check inter 1s fall 2 rise 2
          server web2 172.29.22.22:8080 check inter 1s fall 2 rise 2
      CFG
      mkdir -p /ha/lb2
      sed -e 's/lb1/lb2/; s/state MASTER/state BACKUP/; s/priority 150/priority 100/' \
        /ha/lb1/keepalived.conf > /ha/lb2/keepalived.conf
      presented() {
        openssl s_client -connect "$1:443" -servername www </dev/null 2>/dev/null \
          | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2
      }
      want=$(openssl x509 -in /ha/certs/www.pem -noout -fingerprint -sha256 | cut -d= -f2)
      for _ in $(seq 40); do
        [ "$(presented 172.29.22.11)" = "$want" ] && [ "$(presented 172.29.22.12)" = "$want" ] && break
        sleep 0.5
      done
      # This morning's renewal: a new file, picked up on lb1 only.
      bash /root/.cert-rotation-issue /ha/certs/www.pem
      touch /ha/lb1/start-haproxy
      sleep 3

      cat > /ha/answers/cert-rotation.txt <<'TXT'
      # Which load balancers have to load a renewed certificate themselves?
      # Node names, separated by spaces.
      rotate_on: ?
      # What does moving www from one load balancer to the other rotate?
      vip_move_rotates: ?
      TXT
      cat > /ha/certs/rotate.sh <<'SH'
      #!/bin/bash
      # Run from ops after a renewed certificate has been written to
      # /ha/certs/www.pem. Afterwards every load balancer presents it, and no
      # client saw a failed connection or handshake while it ran.
      set -eu
      echo "rotate: not written yet" >&2
      exit 1
      SH
      chmod +x /ha/certs/rotate.sh

      echo "scenario ready — the certificate each load balancer presents:"
      echo
      for l in lb1:172.29.22.11 lb2:172.29.22.12; do
        printf '  %s  ' "${l%%:*}"
        openssl s_client -connect "${l#*:}:443" -servername www </dev/null 2>/dev/null \
          | openssl x509 -noout -serial -startdate
      done | paste - - 
      printf '  file  '; openssl x509 -in /ha/certs/www.pem -noout -serial -startdate | paste - -
      echo
      echo "  the certificate:      /ha/certs/www.pem  (CA: /ha/certs/ca.pem)"
      echo "  ask one node:         openssl s_client -connect 172.29.22.12:443 -servername www </dev/null"
      echo "  through the VIP:      curl --cacert /ha/certs/ca.pem https://www/"
      echo "  your rotation:        /ha/certs/rotate.sh"
      echo "  your answers:         /ha/answers/cert-rotation.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      if [ ! -f /root/.cert-rotation-issue ] || [ ! -f /root/.cert-rotation-ca.key ]; then
        echo "not yet: this scenario's CA is missing from ops. Reset the lesson."
        exit 1
      fi
      work=$(mktemp -d)
      trap 'touch "$work/stop"; sleep 0.3; rm -rf "$work"' EXIT
      presented() {
        openssl s_client -connect "$1:443" -servername www </dev/null 2>/dev/null \
          | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2 || true
      }
      describe() {
        openssl s_client -connect "$1:443" -servername www </dev/null 2>/dev/null \
          | openssl x509 -noout -serial -startdate 2>/dev/null | paste -sd' ' - || true
      }
      # Every node presents the certificate in /ha/certs/www.pem; $1 says when.
      all_current() {
        local want l ip
        want=$(openssl x509 -in /ha/certs/www.pem -noout -fingerprint -sha256 | cut -d= -f2)
        for l in lb1:172.29.22.11 lb2:172.29.22.12; do
          ip=${l#*:}
          if [ "$(presented "$ip")" != "$want" ]; then
            echo "not yet: $1, ${l%%:*} presents $(describe "$ip")"
            echo "         but /ha/certs/www.pem holds $(openssl x509 -in /ha/certs/www.pem -noout -serial -startdate | paste -sd' ' -)."
            echo "         HAProxy reads the file when it starts or reloads, not when the file changes."
            return 1
          fi
        done
      }

      ans() { awk -F: -v k="$1" '$1 ~ "^[[:space:]]*" k "[[:space:]]*$" { print tolower($2); exit }' /ha/answers/cert-rotation.txt 2>/dev/null || true; }
      on=$(ans rotate_on | grep -oE '\blb[12]\b' | sort -u | paste -sd' ' - || true)
      if [ "$on" != "lb1 lb2" ]; then
        echo "not yet: rotate_on in /ha/answers/cert-rotation.txt is '${on:-nothing}'."
        echo "         Each HAProxy holds its own copy of the certificate in memory. Which of them will"
        echo "         go on presenting an old one after the next renewal unless it is told?"
        exit 1
      fi
      vm=$(ans vip_move_rotates)
      if ! grep -Eq '^[[:space:]]*(nothing|none)\b' <<<"$vm"; then
        echo "not yet: vip_move_rotates is '$(echo $vm)'. Moving www moves an address. Whatever the"
        echo "         node it lands on has loaded is what clients get, old or new."
        exit 1
      fi
      echo "answers: rotate on lb1 and lb2; moving the VIP rotates nothing"

      all_current "before the grader's rotation" || exit 1
      echo "both nodes present the certificate in /ha/certs/www.pem"
      if [ ! -s /ha/certs/rotate.sh ]; then
        echo "not yet: /ha/certs/rotate.sh is missing or empty."
        exit 1
      fi

      # A new renewal, rotated by the student's script while clients connect
      # through www and to each node directly, each request a new handshake.
      bash /root/.cert-rotation-issue /ha/certs/www.pem
      cat > "$work/load.py" <<'PY'
      import http.client, os, ssl, sys, threading, time
      stop, out = sys.argv[1], sys.argv[2]
      ctx = ssl.create_default_context(cafile="/ha/certs/ca.pem")
      lock = threading.Lock()
      ok, bad = {}, []
      def hit(ip):
          while not os.path.exists(stop):
              try:
                  c = http.client.HTTPSConnection(ip, 443, timeout=3, context=ctx)
                  c.connect()
                  c.request("GET", "/", headers={"Host": "www"})
                  r = c.getresponse(); r.read(); c.close()
                  if r.status != 200:
                      raise RuntimeError(f"HTTP {r.status}")
                  with lock: ok[ip] = ok.get(ip, 0) + 1
              except Exception as e:
                  with lock: bad.append(f"{ip}: {type(e).__name__}: {e}")
                  time.sleep(0.05)
      ts = [threading.Thread(target=hit, args=(ip,)) for ip in ("www", "172.29.22.11", "172.29.22.12") for _ in range(2)]
      [t.start() for t in ts]; [t.join() for t in ts]
      with open(out, "w") as f:
          f.write(f"{sum(ok.values())} {len(bad)}\n")
          f.write("\n".join(bad[:3]) + "\n")
      PY
      python3 "$work/load.py" "$work/stop" "$work/result" &
      load=$!
      sleep 1.5
      rc=0
      timeout 90 bash /ha/certs/rotate.sh > "$work/rotate.log" 2>&1 || rc=$?
      sleep 2
      touch "$work/stop"
      wait "$load" || true
      if [ "$rc" -ne 0 ]; then
        echo "not yet: /ha/certs/rotate.sh exited $rc. Its last lines:"
        tail -5 "$work/rotate.log" | sed 's/^/         | /'
        exit 1
      fi
      read -r good failed < "$work/result"
      if [ "$failed" -gt 0 ]; then
        echo "not yet: while rotate.sh ran, $failed of $((good + failed)) connections failed, e.g."
        sed -n '2,4p' "$work/result" | grep . | sed 's/^/         | /' || true
        echo "         Restarting a node, or moving the address, drops whoever is connected to it. A rotation"
        echo "         only has to make each running HAProxy load the new file."
        exit 1
      fi
      sleep 1
      all_current "after rotate.sh" || exit 1
      echo "rotation under load: $good connections, none failed; both nodes present the new certificate"
      echo
      echo "PASS — one certificate everywhere, rotated on every node, with nobody noticing."
