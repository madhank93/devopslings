---
kind: lesson
title: "the second run reports six changes, and the box looks fine"
description: |
  The fleet-agent playbook works. Run it twice and the second run reports
  changed=6 on a box that was already correct. Every run looks like a
  deployment, so the run where something really changed looks the same as all
  the others. Get the second run to changed=0 without hiding the real changes.
name: idempotency
slug: idempotency
createdAt: "2026-10-14"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      install -d /var/lib/devopslings
      userdel fleetagent >/dev/null 2>&1 || true
      rm -rf /etc/fleet-agent /usr/local/bin/fleet-agent /var/log/fleet-agent.log /root/agent
      install -d /root/agent/files /root/agent/templates
      cd /root/agent

      cat > ansible.cfg <<'CFG'
      [defaults]
      inventory = inventory.ini
      interpreter_python = /usr/bin/python3
      CFG
      cat > inventory.ini <<'INV'
      [agents]
      box ansible_connection=local
      INV

      cat > files/fleet-agent <<'SH'
      #!/bin/sh
      # Reports this box to the fleet collector.
      . /etc/fleet-agent/agent.env
      echo "fleet-agent: role=$FLEET_ROLE node=$FLEET_NODE"
      SH
      cat > files/agent.conf <<'CONF'
      collector = https://collector.internal:8443
      interval = 30
      max_conn = 256
      CONF
      cat > templates/agent.env.j2 <<'J2'
      # Managed by Ansible. Rendered {{ ansible_date_time.iso8601 }}.
      FLEET_ROLE=web
      FLEET_NODE={{ inventory_hostname }}
      J2

      # Six tasks report a change on every run, from four causes: commands
      # Ansible cannot see into, two tasks owning one file, a template that
      # embeds the time, and touch.
      cat > site.yml <<'YML'
      - name: fleet-agent is installed and configured
        hosts: agents
        tasks:
          - name: service account exists
            ansible.builtin.shell: id fleetagent >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin fleetagent

          - name: agent binary is installed
            ansible.builtin.command: install -m 0755 {{ playbook_dir }}/files/fleet-agent /usr/local/bin/fleet-agent

          - name: config directory exists
            ansible.builtin.file:
              path: /etc/fleet-agent
              state: directory
              mode: "0755"

          - name: base config is in place
            ansible.builtin.copy:
              src: agent.conf
              dest: /etc/fleet-agent/agent.conf
              mode: "0644"

          - name: web nodes get a higher connection limit
            ansible.builtin.lineinfile:
              path: /etc/fleet-agent/agent.conf
              regexp: '^max_conn'
              line: max_conn = 512

          - name: environment file is rendered
            ansible.builtin.template:
              src: agent.env.j2
              dest: /etc/fleet-agent/agent.env
              mode: "0644"

          - name: log file exists
            ansible.builtin.file:
              path: /var/log/fleet-agent.log
              state: touch
              owner: fleetagent
              mode: "0640"
      YML

      cat > README <<'TXT'
      site.yml installs fleet-agent. After a run the box must have:

        - system user fleetagent, login shell /usr/sbin/nologin
        - /usr/local/bin/fleet-agent, identical to files/fleet-agent, mode 0755
        - /etc/fleet-agent/agent.conf: the lines of files/agent.conf, with
          max_conn = 512 (once) instead of 256
        - /etc/fleet-agent/agent.env with FLEET_ROLE=web and FLEET_NODE=box
        - /var/log/fleet-agent.log owned by fleetagent, mode 0640

      A second run on a box in that state must report changed=0.
      TXT

      ansible-playbook site.yml >/dev/null 2>&1 || true
      echo "scenario ready — /root/agent/site.yml has run once; run it again and read the recap"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      if ! cd /root/agent 2>/dev/null || [ ! -f site.yml ]; then
        echo "not yet: /root/agent/site.yml is gone — reset the lesson to get it back"
        exit 1
      fi
      export ANSIBLE_NOCOLOR=1 ANSIBLE_STDOUT_CALLBACK=default ANSIBLE_DEPRECATION_WARNINGS=False
      log=/var/lib/devopslings/idempotency.run

      if ! syntax=$(ansible-playbook --syntax-check site.yml 2>&1); then
        echo "not yet: site.yml does not parse:"
        tail -n 6 <<<"$syntax" | sed 's/^/         /'
        exit 1
      fi

      # play: run the playbook, leave its output in $log and the recap's
      # changed total in $changed. Fails the check if the run fails.
      play() {
        local rc=0
        ansible-playbook site.yml > "$log" 2>&1 || rc=$?
        changed=$(sed -n '/^PLAY RECAP/,$p' "$log" | grep -oE 'changed=[0-9]+' | cut -d= -f2 | awk '{s+=$1} END {print s+0}' || true)
        : "${changed:=0}"
        if [ "$rc" != 0 ]; then
          echo "not yet: the playbook failed ($1):"
          grep -m1 -E '^(fatal|failed):' "$log" | cut -c1-240 | sed 's/^/         /' || true
          exit 1
        fi
      }
      changed_tasks() {
        awk '/^TASK \[/{t=$0; sub(/^TASK /, "", t); sub(/ \*+$/, "", t)} /^changed:/{print "           " t}' "$log"
      }

      # The end state the README asks for. Prints what is wrong; silent when right.
      end_state() {
        local u sh
        u=$(getent passwd fleetagent || true)
        if [ -z "$u" ]; then echo "there is no fleetagent user"; return; fi
        sh=$(cut -d: -f7 <<<"$u")
        [ "$sh" = /usr/sbin/nologin ] || echo "fleetagent's login shell is $sh, not /usr/sbin/nologin"
        [ "$(cut -d: -f3 <<<"$u")" -lt 1000 ] || echo "fleetagent is not a system user (uid $(cut -d: -f3 <<<"$u"))"
        if ! cmp -s /usr/local/bin/fleet-agent files/fleet-agent; then
          echo "/usr/local/bin/fleet-agent is missing or differs from files/fleet-agent"
        elif [ "$(stat -c %a /usr/local/bin/fleet-agent)" != 755 ]; then
          echo "/usr/local/bin/fleet-agent is mode $(stat -c %a /usr/local/bin/fleet-agent), not 0755"
        fi
        local conf=/etc/fleet-agent/agent.conf n
        if [ ! -f "$conf" ]; then
          echo "$conf does not exist"
        else
          n=$(grep -cxE 'max_conn *= *512' "$conf" || true)
          [ "${n:-0}" = 1 ] || echo "$conf has max_conn = 512 ${n:-0} times, not once"
          ! grep -qE '^max_conn *= *256' "$conf" || echo "$conf still has max_conn = 256"
          for k in 'collector = https://collector.internal:8443' 'interval = 30'; do
            grep -qxF "$k" "$conf" || echo "$conf is missing the line: $k"
          done
        fi
        local env=/etc/fleet-agent/agent.env
        grep -qx 'FLEET_ROLE=web' "$env" 2>/dev/null || echo "$env has no FLEET_ROLE=web line"
        grep -qx 'FLEET_NODE=box' "$env" 2>/dev/null || echo "$env has no FLEET_NODE=box line"
        local lf=/var/log/fleet-agent.log
        if [ ! -f "$lf" ]; then
          echo "$lf does not exist"
        else
          [ "$(stat -c %U "$lf")" = fleetagent ] || echo "$lf is owned by $(stat -c %U "$lf"), not fleetagent"
          [ "$(stat -c %a "$lf")" = 640 ] || echo "$lf is mode $(stat -c %a "$lf"), not 0640"
        fi
      }
      need_end_state() {
        local bad
        bad=$(end_state)
        if [ -n "$bad" ]; then
          echo "not yet: $1, the box is not in the state the README describes:"
          sed 's/^/           /' <<<"$bad"
          exit 1
        fi
      }

      # Grade from a box the playbook has never touched, so a fix applied by
      # hand cannot stand in for one in the playbook.
      userdel fleetagent >/dev/null 2>&1 || true
      rm -rf /etc/fleet-agent /usr/local/bin/fleet-agent /var/log/fleet-agent.log

      play "first run, on a clean box"
      need_end_state "after one run on a clean box"

      play "second run"
      if [ "$changed" != 0 ]; then
        echo "not yet: the second run reported changed=$changed on a box the first run had already set up"
        echo "         these tasks reported a change again:"
        changed_tasks
        echo "         each one either really rewrites something on every run, or cannot tell"
        echo "         whether it did — compare the box before and after a run to see which"
        exit 1
      fi
      need_end_state "after the second run"

      # changed=0 is only worth something if a real change is still reported.
      # Knock one thing out of place at a time; the next run must put it back
      # and say that it did.
      set -- \
        "usermod -s /bin/bash fleetagent|set fleetagent's shell to /bin/bash" \
        "printf '# local edit\n' >> /usr/local/bin/fleet-agent|appended a line to /usr/local/bin/fleet-agent" \
        "sed -i 's/^max_conn.*/max_conn = 256/' /etc/fleet-agent/agent.conf|set max_conn back to 256 in agent.conf" \
        "rm -f /etc/fleet-agent/agent.env|deleted /etc/fleet-agent/agent.env" \
        "chmod 0600 /var/log/fleet-agent.log|changed /var/log/fleet-agent.log to mode 0600"
      for round in "$@"; do
        cmd=${round%%|*} what=${round#*|}
        bash -c "$cmd"
        play "after the check $what"
        bad=$(end_state)
        if [ -n "$bad" ]; then
          echo "not yet: the check $what, and the next run did not put it back:"
          sed 's/^/           /' <<<"$bad"
          exit 1
        fi
        if [ "$changed" = 0 ]; then
          echo "not yet: the check $what. The next run put it back"
          echo "         and reported changed=0. A task changed the box and said it did not,"
          echo "         so the recap can no longer tell you when something drifted."
          echo "         changed_when: false on a task that really changes things does exactly this."
          exit 1
        fi
      done

      echo "PASS — the second run reports changed=0, the end state is the one asked for, and"
      echo "       each piece of drift is put back and reported as a change."
---
