---
kind: lesson
title: "one request, three steps, and only one of them is broken"
description: |
  Three internal services are down. All three tickets say the same thing —
  "connection failed" — and all three are wrong in a different place. One name
  never resolved. One resolved and was refused. One resolved, connected, and
  answered with a number nobody read.
name: resolve-connect-request
slug: resolve-connect-request
createdAt: "2026-08-10"

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
      systemctl stop svc-charlie.service 2>/dev/null || true
      ip netns del svc 2>/dev/null || true
      ip link del to-svc 2>/dev/null || true
      rm -f /etc/dnsmasq.d/lab.conf
      install -d /root/answers /opt/svc

      # ---- the "internal" network, in a namespace ----------------------
      # Both service addresses live on one interface in one namespace. That is
      # deliberate: the two failures the student has to separate are on the same
      # host, so "the box is down" cannot be the answer to either of them.
      ip netns add svc
      ip link add to-svc type veth peer name in0
      ip link set in0 netns svc

      ip addr add 10.70.0.1/24 dev to-svc
      ip link set to-svc up

      ip netns exec svc ip link set lo up
      ip netns exec svc ip addr add 10.70.0.6/24 dev in0
      ip netns exec svc ip addr add 10.70.0.7/24 dev in0
      ip netns exec svc ip link set in0 up
      ip netns exec svc ip route add default via 10.70.0.1

      # charlie answers. It answers 503 to everything, which is the point —
      # bound to .7 specifically, so that .6 has nothing listening on it and
      # refuses instead of being served by this same process.
      cat > /opt/svc/charlie.py <<'PY'
      #!/usr/bin/env python3
      from http.server import BaseHTTPRequestHandler, HTTPServer

      BODY = (b"inventory pool is empty; nothing to serve\n"
              b"served by charlie.internal\n")

      class H(BaseHTTPRequestHandler):
          protocol_version = "HTTP/1.1"

          def do_GET(self):
              self.send_response(503)
              self.send_header("Content-Type", "text/plain")
              self.send_header("Content-Length", str(len(BODY)))
              self.send_header("Retry-After", "120")
              self.end_headers()
              self.wfile.write(BODY)

          def log_message(self, *args):
              pass

      HTTPServer(("10.70.0.7", 8080), H).serve_forever()
      PY
      chmod +x /opt/svc/charlie.py

      cat > /etc/systemd/system/svc-charlie.service <<'UNIT'
      [Unit]
      Description=charlie.internal
      After=network.target

      [Service]
      NetworkNamespacePath=/run/netns/svc
      ExecStart=/usr/bin/python3 /opt/svc/charlie.py
      Restart=always

      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload
      systemctl enable --now svc-charlie.service >/dev/null 2>&1

      # ---- a resolver that answers for real ----------------------------
      # Docker's own resolver is kept as the upstream so that names outside
      # .internal still work. Everything under .internal is answered here and
      # never forwarded, so a name that is not configured is an immediate
      # NXDOMAIN rather than a slow trip to the internet.
      up=$(grep -m1 '^nameserver' /etc/resolv.conf | awk '{print $2}')
      [ -n "$up" ] || up=1.1.1.1
      printf 'nameserver %s\n' "$up" > /etc/dnsmasq-upstream.conf

      install -d /etc/dnsmasq.d
      cat > /etc/dnsmasq.d/lab.conf <<CONF
      listen-address=127.0.0.1
      bind-interfaces
      no-hosts
      local=/internal/
      resolv-file=/etc/dnsmasq-upstream.conf
      address=/bravo.internal/10.70.0.6
      address=/charlie.internal/10.70.0.7
      CONF

      systemctl unmask dnsmasq.service >/dev/null 2>&1 || true
      systemctl enable --now dnsmasq.service >/dev/null 2>&1
      systemctl restart dnsmasq.service

      # resolv.conf is a bind mount in a container, so it is written in place
      # rather than replaced.
      printf 'nameserver 127.0.0.1\noptions timeout:2 attempts:1\n' > /etc/resolv.conf

      # Wait for the resolver to actually be answering before handing the box
      # over, so the first thing the student runs is not a false negative.
      for _ in $(seq 1 20); do
        dig +short +time=1 +tries=1 charlie.internal @127.0.0.1 2>/dev/null | grep -q 10.70.0.7 && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      Three internal services, three tickets, all of them saying
      "connection failed":

        http://alpha.internal:8080/
        http://bravo.internal:8080/
        http://charlie.internal:8080/

      A request to any of them is three separate steps, and each step has its
      own tool:

        1. the name is resolved to an address      dig
        2. a TCP connection is opened to it        nc -vz  (a bare connect)
        3. the HTTP request is written and         curl -v
           a response is read back

      Run all three probes against all three services, in that order. Each
      service fails at exactly one step, and a different one.

      Write /root/answers/request.md with one line per service, exactly:

        alpha:   resolves=<yes|no> connects=<yes|no|na> http=<code|na> step=<resolve|connect|request>
        bravo:   resolves=<yes|no> connects=<yes|no|na> http=<code|na> step=<resolve|connect|request>
        charlie: resolves=<yes|no> connects=<yes|no|na> http=<code|na> step=<resolve|connect|request>

      Use na for a step that could not be attempted because an earlier one
      failed. http= is the HTTP status code as a number when there is one.

      Nothing here needs repairing. This exercise is over when the file
      describes the box correctly — so leave the three services as they are.
      Q

      echo "scenario ready — three services, three different steps"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      ans=/root/answers/request.md
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty."
        echo "         /root/questions.txt has the format."
        exit 1
      fi

      # The scenario has to still be the scenario. This lesson asks for a
      # diagnosis, not a repair, and an answer file describing a box that has
      # since been changed is not a correct answer to anything.
      if ! systemctl is-active --quiet dnsmasq.service; then
        echo "not yet: the resolver on this box is not running any more."
        echo "         this exercise is a diagnosis, not a repair — the three"
        echo "         services are supposed to stay exactly as they were."
        exit 1
      fi
      if [ "$(dig +short +time=2 +tries=1 charlie.internal @127.0.0.1 2>/dev/null)" != "10.70.0.7" ]; then
        echo "not yet: charlie.internal no longer resolves to 10.70.0.7."
        echo "         the box has been changed out from under the answer file."
        exit 1
      fi
      code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://10.70.0.7:8080/ 2>/dev/null || true)
      if [ "$code" != "503" ]; then
        echo "not yet: the service on 10.70.0.7 is answering $code, not what it was."
        echo "         nothing here needed fixing — put it back and describe it."
        exit 1
      fi

      # truth: name  resolves connects http step
      #        alpha is not in the resolver's zone at all
      #        bravo resolves, and nothing is listening on that address
      #        charlie resolves, connects, and answers 503
      # The truth table is a quoted list rather than a heredoc: a heredoc body
      # has to start in column 1, and column 1 ends the YAML block scalar this
      # script lives in.
      fail=0
      for row in "alpha no na na resolve" \
                 "bravo yes no na connect" \
                 "charlie yes yes 503 request"; do
        # shellcheck disable=SC2086
        set -- $row
        name=$1 want_res=$2 want_con=$3 want_http=$4 want_step=$5

        line=$(grep -iE "^[[:space:]]*$name[[:space:]]*:" "$ans" | head -1 || true)
        if [ -z "$line" ]; then
          echo "not yet: there is no '$name:' line in $ans."
          exit 1
        fi

        low=$(printf '%s' "$line" | tr 'A-Z' 'a-z')
        res=$(printf  '%s' "$low" | sed -n 's/.*resolves=\([a-z]*\).*/\1/p')
        con=$(printf  '%s' "$low" | sed -n 's/.*connects=\([a-z]*\).*/\1/p')
        http=$(printf '%s' "$low" | sed -n 's/.*http=\([a-z0-9]*\).*/\1/p')
        step=$(printf '%s' "$low" | sed -n 's/.*step=\([a-z]*\).*/\1/p')

        for f in resolves:"$res" connects:"$con" http:"$http" step:"$step"; do
          if [ -z "${f#*:}" ]; then
            echo "not yet: the $name line has no ${f%%:*}= field yet."
            exit 1
          fi
        done
        case "$res"  in yes|no) ;;    *) echo "not yet: $name resolves=$res — it is yes or no."; exit 1 ;; esac
        case "$con"  in yes|no|na) ;; *) echo "not yet: $name connects=$con — it is yes, no or na."; exit 1 ;; esac
        case "$step" in resolve|connect|request) ;;
          *) echo "not yet: $name step=$step — it is resolve, connect or request."; exit 1 ;;
        esac

        if [ "$res" != "$want_res" ]; then
          fail=1
          echo "not yet: $name — you said resolves=$res."
          case "$name" in
            alpha)   echo "         ask the resolver directly: dig alpha.internal. Look at the"
                     echo "         status in the header, not at whether dig printed something." ;;
            *)       echo "         dig $name.internal returns an address. The name is fine;"
                     echo "         the failure is later than this step." ;;
          esac
          continue
        fi
        if [ "$con" != "$want_con" ]; then
          fail=1
          echo "not yet: $name — you said connects=$con."
          case "$name" in
            alpha)   echo "         there is no address to connect to, so there was no connect"
                     echo "         attempt to report. That is what na is for." ;;
            bravo)   echo "         nc -vz bravo.internal 8080 comes back immediately, and what"
                     echo "         it says is not 'timed out'. Something answered — with a"
                     echo "         refusal. That is still an answer, and it is not a connection." ;;
            charlie) echo "         the TCP connection to charlie is opened successfully. Whatever"
                     echo "         went wrong there went wrong after it was open." ;;
          esac
          continue
        fi
        if [ "$http" != "$want_http" ]; then
          fail=1
          echo "not yet: $name — you said http=$http."
          case "$name" in
            charlie) echo "         curl -v http://charlie.internal:8080/ prints the status line."
                     echo "         The request went out and a response came back; read the number"
                     echo "         in it rather than treating it as a failed connection." ;;
            *)       echo "         no HTTP request was ever written for this one — the request"
                     echo "         never got that far. Use na." ;;
          esac
          continue
        fi
        if [ "$step" != "$want_step" ]; then
          fail=1
          echo "not yet: $name — you said step=$step, and your own three fields disagree"
          echo "         with that. The broken step is the first one that did not succeed."
          continue
        fi
      done

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — three services, three steps, each failure named where it happened:"
      echo "       alpha never resolved, bravo was refused, charlie answered 503."
