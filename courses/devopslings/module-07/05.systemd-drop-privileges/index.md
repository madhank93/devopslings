---
kind: lesson
title: "drop the web server from root to nobody, and keep it on port 80"
description: |
  webportal.service runs as root to bind port 80, which is the wrong reason to
  be root. Dropping it to www-data is one line — and it breaks the service,
  because a non-root process cannot bind a privileged port. The fix is to grant
  back exactly one capability, CAP_NET_BIND_SERVICE, and nothing else, with
  NoNewPrivileges on so the process can never climb back up.
name: systemd-drop-privileges
slug: systemd-drop-privileges
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
      systemctl stop webportal.service 2>/dev/null || true
      rm -f /etc/systemd/system/webportal.service /opt/webportal.py /root/answers/hardening.md
      systemctl daemon-reload 2>/dev/null || true
      systemctl reset-failed webportal.service 2>/dev/null || true

      # Make port 80 a privileged port again
      sysctl -w net.ipv4.ip_unprivileged_port_start=1024 >/dev/null
      install -d /root/answers

      # Write the application
      cat > /opt/webportal.py <<'PY'
      import http.server, socketserver

      class H(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              self.send_response(200)
              self.end_headers()
              self.wfile.write(b"portal up\n")
          def log_message(self, *a):
              pass

      # SO_REUSEADDR: without it a restart inside the socket's TIME_WAIT window fails
      # to bind, which a hardening exercise trips on every time it restarts the unit.
      class Server(socketserver.TCPServer):
          allow_reuse_address = True

      Server(("0.0.0.0", 80), H).serve_forever()
      PY

      # Write the service unit
      cat > /etc/systemd/system/webportal.service <<'UNIT'
      [Unit]
      Description=the customer portal
      After=network.target

      [Service]
      ExecStart=/usr/bin/python3 /opt/webportal.py
      Restart=on-failure

      [Install]
      WantedBy=multi-user.target
      UNIT

      # Reload systemd and start it
      systemctl daemon-reload
      systemctl start webportal.service

      # Write questions file
      cat > /root/questions.txt <<'Q'
      webportal.service serves the customer portal on port 80, and it runs as root:

        $ systemctl show -p MainPID --value webportal.service
        $ ps -o user= -p <that pid>
        root

      A web server that parses untrusted input has no business being root. Harden the
      unit so that:

        - it runs as the www-data user, not root
        - it cannot regain privilege: NoNewPrivileges=yes
        - it STILL serves on port 80

      The last requirement is the interesting one. Port 80 is privileged — a non-root
      process cannot bind it — so the naive fix (just add User=www-data) makes the
      service fail to start:

        OSError: [Errno 13] Permission denied

      Dropping the user is not enough; you have to grant back the one capability that
      binding a low port needs, and only that one. The systemd directives that do it
      are AmbientCapabilities and CapabilityBoundingSet, and the capability is
      CAP_NET_BIND_SERVICE.

      Edit /etc/systemd/system/webportal.service, then:

        $ systemctl daemon-reload
        $ systemctl restart webportal.service
        $ curl -s http://127.0.0.1/          # should still say: portal up

      Then write /root/answers/hardening.md with exactly three lines:

        run_as: <the user the service runs as>
        no_new_privileges: <yes or no>
        bind_capability: <the capability that lets a non-root process bind port 80>
      Q

      echo "scenario ready — webportal serving on :80 as root"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e

      ans=/root/answers/hardening.md

      # It has to still serve. This is the requirement the naive fix breaks: drop
      # the user without the capability and the bind fails, so the service is
      # dead and this returns nothing.
      body=$(curl -s -m 5 http://127.0.0.1/ 2>/dev/null || true)
      if [ "$body" != "portal up" ]; then
        echo "not yet: http://127.0.0.1/ did not return 'portal up' (got: '${body}')."
        echo "         If you set User=www-data without granting CAP_NET_BIND_SERVICE,"
        echo "         the service cannot bind port 80 and fails to start:"
        systemctl --no-pager status webportal.service 2>/dev/null | grep -iE 'permission|denied|failed' | head -1 | sed 's/^/         /'
        exit 1
      fi

      pid=$(systemctl show -p MainPID --value webportal.service 2>/dev/null)
      if [ -z "$pid" ] || [ "$pid" = "0" ] || [ ! -r "/proc/$pid/status" ]; then
        echo "not yet: webportal.service has no running main process."
        echo "         It has to be up and serving: systemctl status webportal"
        exit 1
      fi

      # Not root. The whole point.
      user=$(ps -o user= -p "$pid" 2>/dev/null | tr -d ' ')
      if [ -z "$user" ] || [ "$user" = "root" ]; then
        echo "not yet: the service still runs as ${user:-unknown}, not an"
        echo "         unprivileged user. Add User=www-data (and Group=www-data)."
        exit 1
      fi

      # NoNewPrivileges actually in force, read from the kernel rather than the
      # unit file — this is what the process is really running under.
      nnp=$(awk '/^NoNewPrivs:/{print $2}' "/proc/$pid/status" 2>/dev/null)
      if [ "$nnp" != "1" ]; then
        echo "not yet: NoNewPrivs is '$nnp' for the service process — it can still"
        echo "         gain privilege. Set NoNewPrivileges=yes in the unit."
        exit 1
      fi

      # And it holds exactly the one capability that binding :80 needs. Bit 10
      # (0x400) of the ambient set is CAP_NET_BIND_SERVICE. Reading the ambient
      # set proves the capability is actually granted, not just named in a file.
      amb=$(awk '/^CapAmb:/{print $2}' "/proc/$pid/status" 2>/dev/null)
      amb=${amb:-0}
      if [ $(( 0x$amb & 0x400 )) -eq 0 ]; then
        echo "not yet: the service process does not hold CAP_NET_BIND_SERVICE in"
        echo "         its ambient set (CapAmb: $amb). That capability is what lets"
        echo "         a non-root process bind port 80; grant it with"
        echo "         AmbientCapabilities=CAP_NET_BIND_SERVICE."
        exit 1
      fi

      # The written summary.
      if [ ! -s "$ans" ]; then
        echo "not yet: /root/answers/hardening.md is missing or empty."
        echo "         Three lines: run_as, no_new_privileges, bind_capability."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      a_user=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*run_as[[:space:]]*[:=][[:space:]]*\([a-z0-9_-]*\).*/\1/p' | head -1)
      a_nnp=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*no_new_privileges[[:space:]]*[:=][[:space:]]*\([a-z]*\).*/\1/p' | head -1)
      a_cap=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*bind_capability[[:space:]]*[:=][[:space:]]*//p' | head -1)

      if [ "$a_user" != "www-data" ]; then
        echo "not yet: run_as says '${a_user:-nothing}' — name the unprivileged"
        echo "         user the service now runs as."
        exit 1
      fi
      if [ "$a_nnp" != "yes" ]; then
        echo "not yet: no_new_privileges should be yes."
        exit 1
      fi
      if ! printf '%s' "$a_cap" | grep -qiE 'cap_net_bind_service'; then
        echo "not yet: bind_capability says '${a_cap:-nothing}'. Name the capability"
        echo "         that lets an unprivileged process bind a port below 1024."
        exit 1
      fi

      echo "PASS — the portal still serves on :80, but as www-data with"
      echo "       NoNewPrivileges and only CAP_NET_BIND_SERVICE to its name."
