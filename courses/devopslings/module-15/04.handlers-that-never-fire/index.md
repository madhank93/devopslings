---
kind: lesson
title: "the config file says 200 and the service is still doing 50"
description: |
  The rate limit was raised in group_vars and the playbook was run. The file
  on disk has the new value; the running service never noticed. Re-running the
  playbook changes nothing, because as far as Ansible knows there is nothing
  left to change. Find out where the restart went, and make the handler fire
  on a change, once, and never when nothing changed.
name: handlers-that-never-fire
slug: handlers-that-never-fire
createdAt: "2026-10-14"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      systemctl stop ratelimiter.service 2>/dev/null || true
      rm -rf /root/ansible /etc/ratelimiter /var/lib/ratelimiter /etc/logrotate.d/ratelimiter
      install -d /etc/ratelimiter /var/lib/ratelimiter

      # The daemon reads its config once, at start or on SIGHUP, and serves
      # what it loaded. Every load is appended to a log, so the check can count
      # restarts and reloads without trusting timestamps.
      cat > /usr/local/bin/ratelimiter <<'PY'
      #!/usr/bin/env python3
      import http.server, os, signal, time

      CONF = "/etc/ratelimiter/ratelimiter.conf"
      LOADS = "/var/lib/ratelimiter/loads"
      loaded = ""

      def load(*_):
          global loaded
          pairs = []
          with open(CONF) as f:
              for line in f:
                  line = line.split("#", 1)[0].strip()
                  if "=" in line:
                      k, v = line.split("=", 1)
                      pairs.append(f"{k.strip()}={v.strip()}")
          loaded = "\n".join(sorted(pairs)) + "\n"
          with open(LOADS, "a") as f:
              f.write(f"{time.time():.3f} pid={os.getpid()} {' '.join(sorted(pairs))}\n")

      class H(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              body = loaded.encode()
              self.send_response(200)
              self.send_header("Content-Type", "text/plain")
              self.end_headers()
              self.wfile.write(body)
          def log_message(self, *a):
              pass

      load()
      signal.signal(signal.SIGHUP, load)
      http.server.HTTPServer(("127.0.0.1", 8471), H).serve_forever()
      PY
      chmod 0755 /usr/local/bin/ratelimiter

      cat > /etc/systemd/system/ratelimiter.service <<'UNIT'
      [Unit]
      Description=Edge rate limiter
      After=network.target

      [Service]
      ExecStart=/usr/local/bin/ratelimiter
      ExecReload=/bin/kill -HUP $MAINPID
      Restart=on-failure

      [Install]
      WantedBy=multi-user.target
      UNIT
      systemctl daemon-reload

      install -d /root/ansible/templates /root/ansible/files /root/ansible/group_vars
      cd /root/ansible

      cat > ansible.cfg <<'CFG'
      [defaults]
      inventory = inventory.ini
      CFG

      cat > inventory.ini <<'INV'
      [edge]
      localhost ansible_connection=local ansible_python_interpreter=/usr/bin/python3
      INV

      cat > group_vars/edge.yml <<'VARS'
      ratelimiter_rps: 50
      ratelimiter_burst: 100
      VARS

      cat > templates/ratelimiter.conf.j2 <<'J2'
      # Managed by Ansible. Edit group_vars/edge.yml, not this file.
      requests_per_second = {{ ratelimiter_rps }}
      burst = {{ ratelimiter_burst }}
      J2

      # The task below asks for files/ratelimiter.logrotate. This name does
      # not match, which is the failure that eats the handler.
      cat > files/ratelimiter-logrotate <<'LR'
      /var/log/ratelimiter/*.log {
          weekly
          rotate 4
          compress
          missingok
          notifempty
      }
      LR

      cat > site.yml <<'YML'
      - name: Configure the edge rate limiter
        hosts: edge
        gather_facts: false
        tasks:
          - name: Write ratelimiter config
            ansible.builtin.template:
              src: templates/ratelimiter.conf.j2
              dest: /etc/ratelimiter/ratelimiter.conf
              mode: "0644"
            notify: Restart ratelimiter

          - name: Ensure ratelimiter is running
            ansible.builtin.systemd_service:
              name: ratelimiter
              state: started
              enabled: true

          - name: Install logrotate policy
            ansible.builtin.copy:
              src: files/ratelimiter.logrotate
              dest: /etc/logrotate.d/ratelimiter
              mode: "0644"

        handlers:
          - name: Restart ratelimiter
            ansible.builtin.systemd_service:
              name: ratelimiter
              state: started
      YML

      # Yesterday's deploy at 50, then today's change to 200. Both runs fail
      # on the logrotate task, after the config task has already changed.
      ansible-playbook site.yml >/dev/null 2>&1 || true
      sed -i 's/^ratelimiter_rps: .*/ratelimiter_rps: 200/' group_vars/edge.yml
      ansible-playbook site.yml >/dev/null 2>&1 || true

      for _ in $(seq 20); do
        curl -fsS http://127.0.0.1:8471/ >/dev/null 2>&1 && break
        sleep 0.5
      done
      live=$(curl -fsS http://127.0.0.1:8471/ 2>/dev/null | sed -n 's/^requests_per_second=//p' || true)
      disk=$(sed -n 's/^requests_per_second *= *//p' /etc/ratelimiter/ratelimiter.conf)
      if [ "$live" != 50 ] || [ "$disk" != 200 ]; then
        echo "init: expected file=200 running=50, got file=$disk running=$live" >&2
        exit 1
      fi
      echo "scenario ready: /etc/ratelimiter/ratelimiter.conf says 200, the service is running 50"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      cd /root/ansible
      conf=/etc/ratelimiter/ratelimiter.conf
      url=http://127.0.0.1:8471/
      out=/root/.verify-playbook.out

      loads() { wc -l < /var/lib/ratelimiter/loads 2>/dev/null || echo 0; }
      live() { curl -fsS "$url" 2>/dev/null || true; }
      # The file as the daemon would load it: comments dropped, key=value, sorted.
      ondisk() {
        sed -e 's/#.*//' -e 's/[[:space:]]*=[[:space:]]*/=/' -e 's/^[[:space:]]*//' \
            -e 's/[[:space:]]*$//' "$conf" 2>/dev/null | grep '=' | sort || true
      }
      settle() {
        for _ in $(seq 10); do
          [ -n "$(live)" ] && break
          sleep 0.5
        done
        sleep 1.5
      }
      play() {
        set +e
        ansible-playbook site.yml "$@" > "$out" 2>&1
        rc=$?
        set -e
        settle
        return 0
      }
      show_failure() {
        echo "         the playbook exited $rc. The failing task:"
        grep -E '^(TASK \[|fatal:|\[ERROR\])' "$out" | grep -B1 -E '^(fatal:|\[ERROR\])' \
          | head -6 | cut -c1-200 | sed 's/^/           /' || true
      }

      if [ -z "$(live)" ]; then
        echo "not yet: ratelimiter is not answering on 127.0.0.1:8471"
        echo "         systemctl status ratelimiter; journalctl -u ratelimiter -n 20"
        exit 1
      fi

      vars_rps=$(ansible-inventory --host localhost 2>/dev/null | jq -r '.ratelimiter_rps // empty' || true)
      cur_rps=$(ondisk | sed -n 's/^requests_per_second=//p')

      # 1. The box as it stands: the running config must be what is on disk.
      if [ "$(live)" != "$(ondisk)" ]; then
        if [ -n "$vars_rps" ] && [ "$cur_rps" != "$vars_rps" ]; then
          echo "not yet: the file says requests_per_second=$cur_rps, which is not your group_vars"
          echo "         value ($vars_rps). An earlier check run wrote it with -e, and the"
          echo "         playbook failed before anything restarted the service."
          echo "         Run your playbook to put your value back, then restart if needed."
          exit 1
        fi
        echo "not yet: the file and the running service disagree"
        echo "         on disk:  $(ondisk | tr '\n' ' ')"
        echo "         running:  $(live | tr '\n' ' ')"
        echo "         whatever wrote the file did not restart the service. If it was a"
        echo "         playbook run, re-running will not fix it: the template task is"
        echo "         already 'ok', so nothing notifies the handler again."
        exit 1
      fi

      n=$((1000 + RANDOM % 9000))
      while [ "$n" = "$vars_rps" ] || [ "$n" = "$cur_rps" ]; do n=$((n + 1)); done

      # A hand edit of the file must not restart anything: the restart has to
      # come from the playbook, not from a watcher on the file.
      before=$(loads)
      cp "$conf" "$out.conf"
      sed -i "s/^\([[:space:]]*requests_per_second[[:space:]]*=\).*/\1 $n/" "$conf"
      sleep 2
      after=$(loads)
      cat "$out.conf" > "$conf"
      if [ "$after" -ne "$before" ]; then
        echo "not yet: editing $conf by hand restarted the service"
        echo "         something outside Ansible (a systemd .path unit, an inotify watcher)"
        echo "         restarts on any write to the file. Remove it: the restart belongs"
        echo "         in a handler that the playbook's config task notifies."
        exit 1
      fi

      # 2. A real change: exactly one restart or reload, and the new value live.
      # The logrotate policy is removed first, so only a run that installs it passes.
      rm -f /etc/logrotate.d/ratelimiter
      before=$(loads)
      play -e "ratelimiter_rps=$n"
      after=$(loads)
      if [ "$rc" -ne 0 ]; then
        echo "not yet: with ratelimiter_rps changed to $n, the playbook failed"
        show_failure
        if ! grep -q '^RUNNING HANDLER' "$out"; then
          echo "         a failed play skips its handlers, so the change is on disk and"
          echo "         the service never hears about it."
        fi
        exit 1
      fi
      if [ ! -s /etc/logrotate.d/ratelimiter ]; then
        echo "not yet: the playbook succeeded but did not install /etc/logrotate.d/ratelimiter"
        if grep -q '^\.\.\.ignoring' "$out"; then
          echo "         a failing task is being ignored (ignore_errors). Fix what it"
          echo "         copies instead, so the run both succeeds and installs the policy."
        else
          echo "         the logrotate task is gone or no longer fails visibly. It is part"
          echo "         of the deploy: fix the file it copies rather than removing it."
        fi
        exit 1
      fi
      if ! ondisk | grep -qx "requests_per_second=$n"; then
        echo "not yet: ran the playbook with -e ratelimiter_rps=$n, and $conf"
        echo "         does not say $n. The template has to use the variable."
        exit 1
      fi
      delta=$((after - before))
      if [ "$delta" -eq 0 ]; then
        if grep -q '^RUNNING HANDLER' "$out"; then
          echo "not yet: the config changed and the handler ran, but the service did"
          echo "         not restart or reload. It is still serving:"
          echo "           $(live | tr '\n' ' ')"
          echo "         look at what the handler asks systemd for. 'started' on a"
          echo "         service that is already running is a no-op."
        else
          echo "not yet: the config changed and no handler ran"
          echo "         is the template task notifying a handler, and does it report"
          echo "         'changed' when the file changes?"
        fi
        exit 1
      fi
      if [ "$delta" -gt 1 ]; then
        echo "not yet: one config change restarted or reloaded the service $delta times"
        echo "         a change should cost one restart. Look for a restart task as well"
        echo "         as a handler, or two handlers that both restart."
        exit 1
      fi
      if [ "$(live)" != "$(ondisk)" ]; then
        echo "not yet: the service restarted, but it is serving something other than the file"
        echo "         on disk:  $(ondisk | tr '\n' ' ')"
        echo "         running:  $(live | tr '\n' ' ')"
        exit 1
      fi

      # 3. No change: the same run again must not touch the service.
      before=$(loads)
      play -e "ratelimiter_rps=$n"
      after=$(loads)
      if [ "$rc" -ne 0 ]; then
        echo "not yet: the second run, with nothing to change, failed"
        show_failure
        exit 1
      fi
      if [ "$after" -ne "$before" ]; then
        if grep -q '^RUNNING HANDLER' "$out"; then
          echo "not yet: a run that changed nothing still ran the restart handler"
          echo "         something notifies it on every run: a task that always"
          echo "         reports 'changed' (a command, or changed_when: true)."
        else
          echo "not yet: a run that changed nothing restarted the service anyway"
          echo "         a restart in the task list runs every time. That hides the bug"
          echo "         and drops connections on every deploy, change or not. The"
          echo "         restart belongs in a handler, notified by the config task."
        fi
        exit 1
      fi

      # 4. Put back the value from group_vars, which is itself a change.
      before=$(loads)
      play
      after=$(loads)
      if [ "$rc" -ne 0 ]; then
        echo "not yet: restoring the group_vars value, the playbook failed"
        show_failure
        exit 1
      fi
      if [ $((after - before)) -ne 1 ] || [ "$(live)" != "$(ondisk)" ]; then
        echo "not yet: changing ratelimiter_rps back from $n did not restart the service once"
        echo "         on disk:  $(ondisk | tr '\n' ' ')"
        echo "         running:  $(live | tr '\n' ' ')"
        exit 1
      fi

      echo "PASS: a config change restarts the service once, a no-op run leaves it alone,"
      echo "      and the running config matches the file."
---
