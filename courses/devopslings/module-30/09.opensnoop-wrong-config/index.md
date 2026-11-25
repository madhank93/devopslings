---
kind: lesson
title: "the config was changed, the service restarted, and nothing changed"
description: |
  Support asked for the greeter to say "bonjour". The change is in
  /etc/greeter/greeter.conf, the service has been restarted twice, and it
  still says "hello". The edit is fine; the service never reads it. Which file
  it does read is one opensnoop away — and the path it prints is not quite the
  answer.
name: opensnoop-wrong-config
slug: opensnoop-wrong-config
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
      systemctl stop greeter.service 2>/dev/null || true
      systemctl reset-failed greeter.service 2>/dev/null || true
      rm -rf /opt/greeter /etc/greeter /var/lib/greeter \
             /etc/systemd/system/greeter.service /root/answers/config.md
      id greeter >/dev/null 2>&1 || useradd --system --home-dir /var/lib/greeter \
          --no-create-home --shell /usr/sbin/nologin greeter
      install -d /root/answers
      install -d -o greeter -g greeter /var/lib/greeter
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

      # ---- the service ---------------------------------------------------
      # It takes the first config file it finds. The search list is built at
      # runtime from settings, so it is not one grep away in the source.
      install -d /opt/greeter
      cat > /opt/greeter/greeter.py <<'PY'
      import http.server, os

      with open("/proc/self/comm", "w") as f:
          f.write("greeter")

      NAME = "greeter.conf"
      SEARCH = [os.environ.get("GREETER_CONF", ""), NAME,
                os.path.join(os.path.expanduser("~"), ".config", "greeter", NAME),
                os.path.join("/etc", "greeter", NAME)]

      def load():
          for p in SEARCH:
              try:
                  with open(p) as f:
                      text = f.read()
              except OSError:
                  continue
              conf = {}
              for line in text.splitlines():
                  if "=" in line and not line.lstrip().startswith("#"):
                      k, v = line.split("=", 1)
                      conf[k.strip()] = v.strip()
              return conf
          return {}

      GREETING = load().get("greeting", "hello")

      class H(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              body = (GREETING + "\n").encode()
              self.send_response(200)
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)
          def log_message(self, *a):
              pass

      http.server.HTTPServer(("127.0.0.1", 8090), H).serve_forever()
      PY
      # The copy a release left in the working directory, found first.
      printf '# defaults shipped with greeter 1.4\ngreeting = hello\nport = 8090\n' \
        > /opt/greeter/greeter.conf
      install -d /etc/greeter
      printf '# greeter settings\n# 2026-11-20 support ticket 4411: greet in French\ngreeting = bonjour\n' \
        > /etc/greeter/greeter.conf
      install -d /var/lib/devopslings
      sha256sum /opt/greeter/greeter.py > /var/lib/devopslings/greeter.sha256

      cat > /etc/systemd/system/greeter.service <<'U'
      [Unit]
      Description=Says hello

      [Service]
      User=greeter
      WorkingDirectory=/opt/greeter
      ExecStart=/usr/bin/python3 /opt/greeter/greeter.py
      Restart=on-failure
      U
      systemctl daemon-reload
      systemctl start greeter.service
      for _ in $(seq 40); do
        curl -fsS http://127.0.0.1:8090/ >/dev/null 2>&1 && break
        sleep 0.25
      done

      echo "scenario ready — /etc/greeter/greeter.conf says bonjour; curl 127.0.0.1:8090 says hello"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      set -e
      ans=/root/answers/config.md
      real=/opt/greeter/greeter.conf

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty. Name the file greeter really"
        echo "         reads:  path: <absolute path>"
        exit 1
      fi
      p=$(sed -n 's/^[[:space:]]*path[[:space:]]*[:=][[:space:]]*//p' "$ans" | head -n 1 | tr -d "\`\"'" | sed 's/[[:space:]]*$//')
      case "$p" in
        "$real") ;;
        /etc/greeter/greeter.conf)
          echo "not yet: path says $p — the file that was edited, which greeter never"
          echo "         opens. Watch its opens while it starts: opensnoop -n greeter,"
          echo "         or strace -f -e trace=openat, then restart it."
          exit 1 ;;
        greeter.conf|./greeter.conf)
          echo "not yet: path says $p, which is what the trace prints — the path as"
          echo "         greeter passed it. A relative path resolves against the"
          echo "         process's working directory; /proc/<pid>/cwd says which."
          exit 1 ;;
        *)
          echo "not yet: path says '${p:-nothing}', and greeter does not read its"
          echo "         greeting from there. Watch its opens while it starts, and"
          echo "         take the first config file that open() succeeds on."
          exit 1 ;;
      esac

      if ! sha256sum -c --quiet /var/lib/devopslings/greeter.sha256 >/dev/null 2>&1; then
        echo "not yet: /opt/greeter/greeter.py was changed. The code is fine; the fix"
        echo "         is a config file, so leave the program as it shipped."
        exit 1
      fi

      # Behaviour after a clean restart is the grade, not the files.
      systemctl restart greeter.service
      got=""
      for _ in $(seq 40); do
        got=$(curl -fsS http://127.0.0.1:8090/ 2>/dev/null || true)
        [ -n "$got" ] && break
        sleep 0.25
      done
      if [ -z "$got" ]; then
        echo "not yet: greeter does not answer on 127.0.0.1:8090 after a restart."
        echo "         journalctl -u greeter says why."
        exit 1
      fi
      if [ "$got" != "bonjour" ]; then
        echo "not yet: greeter says '$got' after a restart. The right file is named;"
        echo "         the fix has not landed there — make the file greeter reads"
        echo "         say bonjour, or stop it shadowing /etc/greeter/greeter.conf."
        exit 1
      fi

      echo "PASS — greeter reads $real first, and now says bonjour."
