---
kind: lesson
title: "the setup script that only works on a machine it has never seen"
description: |
  bootstrap-node is run once per new host and it works. Run it twice and the
  config has two of everything; run it once and interrupt it, and the host is
  left in a state the script cannot recover from. Both happen, routinely.
name: idempotent-by-construction
slug: idempotent-by-construction
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      install -d /var/lib/devopslings /root/answers

      cat > /usr/local/bin/reset-node <<'SH'
      #!/bin/bash
      # Puts the box back to "fresh host" for this lesson.
      set -euo pipefail
      rm -rf /etc/nodeagent /srv/nodeagent /opt/nodeagent-1.4
      userdel nodeagent 2>/dev/null || true
      groupdel nodeagent 2>/dev/null || true
      rm -f /etc/profile.d/nodeagent.sh
      SH
      chmod 0755 /usr/local/bin/reset-node

      cat > /usr/local/bin/bootstrap-node <<'SH'
      #!/bin/bash
      # Prepare a fresh host to run the node agent.
      set -euo pipefail

      # 1. The account. Fails outright if it is already there.
      groupadd nodeagent
      useradd --system --gid nodeagent --no-create-home nodeagent

      # 2. The layout.
      mkdir /etc/nodeagent
      mkdir /srv/nodeagent
      mkdir /opt/nodeagent-1.4

      # 3. Config. Appended, so a second run has two of everything.
      echo "endpoint=https://collector.internal:8443" >> /etc/nodeagent/agent.conf
      echo "queue_dir=/srv/nodeagent" >> /etc/nodeagent/agent.conf

      # 4. PATH entry, also appended.
      echo 'export PATH="$PATH:/opt/nodeagent-1.4/bin"' >> /etc/profile.d/nodeagent.sh

      echo "bootstrap-node: done"
      SH
      chmod 0755 /usr/local/bin/bootstrap-node

      /usr/local/bin/reset-node

      cat > /root/questions.txt <<'Q'
      /usr/local/bin/bootstrap-node prepares a fresh host. It is run by hand,
      sometimes twice, and sometimes interrupted half way.

      Make it idempotent: running it any number of times, in any combination
      with interrupted runs, must leave exactly the same end state as running it
      once, and must exit 0 every time.

      The end state, on a fresh host, is:

        - group nodeagent, and system user nodeagent in it
        - directories /etc/nodeagent, /srv/nodeagent, /opt/nodeagent-1.4
        - /etc/nodeagent/agent.conf containing exactly these two lines:
            endpoint=https://collector.internal:8443
            queue_dir=/srv/nodeagent
        - /etc/profile.d/nodeagent.sh containing exactly one PATH line

      The check runs it once from clean, then twice more, then simulates an
      interrupted run and runs it again — and compares the end state each time.
      Q

      echo "scenario ready — bootstrap-node works once on a fresh host and not twice"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      bin=/usr/local/bin/bootstrap-node
      if [ ! -x "$bin" ]; then
        echo "not yet: $bin is missing or not executable"
        exit 1
      fi

      # A fingerprint of everything the script is supposed to establish.
      snapshot() {
        {
          getent group nodeagent  | cut -d: -f1,3 || true
          getent passwd nodeagent | cut -d: -f1,4 || true
          for d in /etc/nodeagent /srv/nodeagent /opt/nodeagent-1.4; do
            [ -d "$d" ] && echo "dir $d"
          done
          echo "--- agent.conf"
          sort /etc/nodeagent/agent.conf 2>/dev/null || true
          echo "--- profile.d"
          sort /etc/profile.d/nodeagent.sh 2>/dev/null || true
        } | sha256sum | awk '{print $1}'
      }

      run_it() {
        set +e
        out=$("$bin" 2>&1); rc=$?
        set -e
        printf '%s' "$out" > /tmp/bootstrap.out
        return $rc
      }

      /usr/local/bin/reset-node

      # Run 1 — from clean.
      if ! run_it; then
        echo "not yet: the first run on a fresh host failed"
        sed 's/^/         /' /tmp/bootstrap.out | tail -5
        exit 1
      fi
      first=$(snapshot)

      # The end state has to be the specified one, not merely stable.
      conf_lines=$(wc -l < /etc/nodeagent/agent.conf 2>/dev/null || echo 0)
      prof_lines=$(grep -c . /etc/profile.d/nodeagent.sh 2>/dev/null || echo 0)
      if [ "$conf_lines" -ne 2 ]; then
        echo "not yet: after one run /etc/nodeagent/agent.conf has $conf_lines lines, expected 2"
        sed 's/^/           /' /etc/nodeagent/agent.conf 2>/dev/null | head -6
        exit 1
      fi
      if ! getent passwd nodeagent >/dev/null; then
        echo "not yet: after one run there is no nodeagent user"
        exit 1
      fi

      # Runs 2 and 3 — must succeed and change nothing.
      for n in 2 3; do
        if ! run_it; then
          echo "not yet: run $n exited non-zero on a host that was already bootstrapped"
          sed 's/^/         /' /tmp/bootstrap.out | tail -5
          echo "         the second run is the one that matters: creating something that"
          echo "         already exists has to be a no-op, not an error."
          exit 1
        fi
        now=$(snapshot)
        if [ "$now" != "$first" ]; then
          echo "not yet: run $n changed the end state"
          echo "         agent.conf now has $(wc -l < /etc/nodeagent/agent.conf) lines:"
          sed 's/^/           /' /etc/nodeagent/agent.conf | head -6
          echo "         appending on every run is the usual cause."
          exit 1
        fi
      done

      # An interrupted run: the account and one directory exist, nothing else.
      /usr/local/bin/reset-node
      groupadd nodeagent
      useradd --system --gid nodeagent --no-create-home nodeagent
      mkdir -p /etc/nodeagent

      if ! run_it; then
        echo "not yet: after a half-finished run, bootstrap-node could not complete"
        sed 's/^/         /' /tmp/bootstrap.out | tail -5
        echo "         a script that only works on a pristine host cannot recover from"
        echo "         its own interruption — which is the state it will most often"
        echo "         actually meet."
        exit 1
      fi
      resumed=$(snapshot)
      if [ "$resumed" != "$first" ]; then
        echo "not yet: recovering from a half-finished run reached a different end state"
        exit 1
      fi

      echo "PASS — same end state after 1, 2 and 3 runs, and after resuming a"
      echo "       half-finished one."
---
