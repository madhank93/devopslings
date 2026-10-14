---
kind: lesson
title: "twelve boxes, one command, and the two it never asked"
description: |
  The fleet is twelve web boxes and one ad-hoc command should reach all of
  them. It reaches nine. One failure is printed in red and easy to spot. The
  other two produce no output at all, because the inventory never asked them,
  and a host that was never asked cannot fail.
name: inventory-and-ad-hoc
slug: inventory-and-ad-hoc
createdAt: "2026-10-14"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      systemctl stop 'fleet-box@*' >/dev/null 2>&1 || true
      # The misnamed host_vars file sends web07 to port 22. Nothing may answer
      # there, or the loud failure turns into a quiet wrong-box success.
      systemctl stop ssh.service ssh.socket >/dev/null 2>&1 || true
      rm -rf /root/fleet
      install -d /root/fleet/host_vars /var/lib/devopslings

      # Every box shares this machine's filesystem but runs its own sshd, on its
      # own port, inside its own UTS namespace. The namespace is what gives each
      # one a distinct hostname, so a fact gathered from the wrong box is visibly
      # wrong rather than identical.
      id deploy >/dev/null 2>&1 || useradd -m -s /bin/bash deploy
      # '*' means "no password" without counting as locked; sshd running without
      # PAM refuses key logins to a locked account.
      usermod -p '*' deploy
      ssh-keygen -A >/dev/null 2>&1
      install -d -m 0700 /root/.ssh
      rm -f /root/.ssh/fleet_ed25519 /root/.ssh/fleet_ed25519.pub
      ssh-keygen -q -t ed25519 -N '' -C fleet -f /root/.ssh/fleet_ed25519
      install -d -m 0700 -o deploy -g deploy /home/deploy/.ssh
      install -m 0600 -o deploy -g deploy /root/.ssh/fleet_ed25519.pub /home/deploy/.ssh/authorized_keys

      # The boxes read their own sshd config, so another lesson rewriting
      # /etc/ssh/sshd_config cannot change who may log in. UsePAM no keeps
      # pam_nologin out of it: this box never runs systemd-user-sessions, so
      # /run/nologin would refuse every login.
      install -d /etc/fleet-box
      cat > /etc/fleet-box/sshd_config <<'CFG'
      HostKey /etc/ssh/ssh_host_ed25519_key
      PidFile none
      UsePAM no
      PubkeyAuthentication yes
      PasswordAuthentication no
      AuthorizedKeysFile .ssh/authorized_keys
      CFG
      cat > /etc/systemd/system/fleet-box@.service <<'UNIT'
      [Unit]
      Description=fleet box web%i

      [Service]
      # Stopping ssh.service deletes /run/sshd, which sshd refuses to start without.
      ExecStartPre=/bin/mkdir -p /run/sshd
      ExecStart=/usr/bin/unshare --uts sh -c "hostname web%i && exec /usr/sbin/sshd -D -e -f /etc/fleet-box/sshd_config -p 22%i"
      Restart=on-failure
      UNIT
      systemctl daemon-reload
      for n in $(seq -w 1 12); do systemctl start "fleet-box@$n"; done
      for n in $(seq -w 1 12); do
        for _ in $(seq 30); do
          ss -ltn "sport = :22$n" | grep -q LISTEN && break
          sleep 0.2
        done
      done

      cd /root/fleet
      cat > ansible.cfg <<'CFG'
      [defaults]
      inventory = hosts.ini
      host_key_checking = False
      interpreter_python = /usr/bin/python3
      CFG

      # Two faults, one loud and one silent. host_vars/web7.yml does not match
      # the inventory name web07, so web07 falls back to port 22 and is refused.
      # web11 and web12 sit in a group that is not a child of web, so a run
      # against web never mentions them.
      cat > hosts.ini <<'INV'
      # Web tier. Ports live in host_vars/; every box is reached as deploy.
      [web]
      web[01:10]

      # Added for the October canary rollout.
      [web_canary]
      web11
      web12

      [web:vars]
      ansible_host=127.0.0.1
      ansible_user=deploy
      ansible_ssh_private_key_file=/root/.ssh/fleet_ed25519
      INV

      echo "name,ssh_port" > cmdb.csv
      for n in $(seq -w 1 12); do
        f=host_vars/web$n.yml
        [ "$n" = 07 ] && f=host_vars/web7.yml
        echo "ansible_port: 22$n" > "$f"
        echo "web$n,22$n" >> cmdb.csv
      done

      echo "scenario ready — /root/fleet holds the inventory; cmdb.csv lists the twelve boxes"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      if ! cd /root/fleet 2>/dev/null; then
        echo "not yet: /root/fleet is gone — reset the lesson to get it back"
        exit 1
      fi
      export ANSIBLE_HOST_KEY_CHECKING=False ANSIBLE_DEPRECATION_WARNINGS=False ANSIBLE_NOCOLOR=1

      fleet=$(seq -f 'web%02g' 1 12)
      listed=$(ansible web --list-hosts 2>/dev/null | sed 1d | awk '{print $1}') || true
      everything=$(ansible all --list-hosts 2>/dev/null | sed 1d | awk '{print $1}') || true

      if [ -z "$listed" ]; then
        echo "not yet: \`ansible web --list-hosts\` in /root/fleet finds no hosts at all"
        echo "         check that ansible.cfg still names the inventory and that it parses:"
        ansible-inventory --graph 2>&1 | head -8 | sed 's/^/           /' || true
        exit 1
      fi

      outside="" absent="" extra=""
      for h in $fleet; do
        grep -qx "$h" <<<"$listed" && continue
        if grep -qx "$h" <<<"$everything"; then outside="$outside $h"; else absent="$absent $h"; fi
      done
      for h in $listed; do
        grep -qx "$h" <<<"$fleet" || extra="$extra $h"
      done
      if [ -n "$outside" ]; then
        echo "not yet: in the inventory but not in group web:$outside"
        echo "         \`ansible web\` only asks the hosts in that group, so these were never"
        echo "         contacted, and a host that was never contacted prints nothing."
        echo "         \`ansible-inventory --graph\` shows which group each host is in."
        exit 1
      fi
      if [ -n "$absent" ]; then
        echo "not yet: missing from the inventory entirely:$absent — the fleet is web01 to web12 (cmdb.csv)"
        exit 1
      fi
      if [ -n "$extra" ]; then
        echo "not yet: group web also lists$extra, which is not one of the twelve boxes in cmdb.csv"
        exit 1
      fi

      # Ask every box for its own hostname. Each one answers with the name its
      # sshd was started under, so a host whose connection settings reach some
      # other box is caught, not just one that cannot connect.
      out=/var/lib/devopslings/fleet-seen
      rm -f "$out"
      cat > /var/lib/devopslings/fleet-check.yml <<'YML'
      - hosts: web
        gather_facts: false
        tasks:
          - ansible.builtin.setup:
              filter: ansible_hostname
            register: seen
            ignore_unreachable: true
            ignore_errors: true
          - ansible.builtin.copy:
              dest: "{{ out }}"
              content: |
                {% for h in ansible_play_hosts_all %}
                {{ h }} {{ hostvars[h].seen.ansible_facts.ansible_hostname | default('-') }} {{ hostvars[h].seen.msg | default('') | replace('\r', '') | replace('\n', ' ') }}
                {% endfor %}
            delegate_to: localhost
            connection: local
            run_once: true
      YML
      run=$(ansible-playbook /var/lib/devopslings/fleet-check.yml -e "out=$out" 2>&1) || true
      if [ ! -s "$out" ]; then
        echo "not yet: could not run a play against group web from /root/fleet:"
        tail -n 8 <<<"$run" | sed 's/^/           /'
        exit 1
      fi

      bad=0
      for h in $fleet; do
        line=$(grep "^$h " "$out" || true)
        name=$(awk '{print $2}' <<<"$line")
        if [ -z "$line" ] || [ "$name" = "-" ]; then
          msg=$(cut -d' ' -f3- <<<"$line" | sed 's/Task failed: //' | cut -c1-160)
          [ "$bad" = 0 ] && echo "not yet: $h is in group web but did not answer"
          echo "         $h: ${msg:-no result}"
          bad=1
        elif [ "$name" != "$h" ]; then
          [ "$bad" = 0 ] && echo "not yet: $h answered, but the machine that answered calls itself '$name'"
          echo "         $h reached '$name' — its connection settings point at a different box"
          bad=1
        fi
      done
      [ "$bad" = 0 ] || exit 1

      echo "PASS — all twelve boxes are in group web, and each one answered with its own hostname."
---
