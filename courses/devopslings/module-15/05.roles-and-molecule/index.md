---
kind: lesson
title: "the playbook that only works on the box it was written on"
description: |
  nodeagent.yml sets up the node agent, and it works, here. Point it at a
  fresh Debian host and it fails on its first task, because it leans on a user
  and a directory someone made by hand two years ago. Turn it into a role with
  defaults, and prove it with a molecule scenario that converges a clean
  target from nothing and checks the result.
name: roles-and-molecule
slug: roles-and-molecule
createdAt: "2026-10-14"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      rm -rf /root/platform /etc/nodeagent /srv/nodeagent /var/log/nodeagent-install.log
      rm -rf /var/lib/molecule-instances /root/.cache/molecule
      userdel nodeagent 2>/dev/null || true
      groupdel nodeagent 2>/dev/null || true

      # The hand-made state the playbook silently depends on.
      groupadd --system nodeagent
      useradd --system --gid nodeagent --no-create-home --shell /usr/sbin/nologin nodeagent
      install -d -o root -g nodeagent -m 0750 /etc/nodeagent

      install -d /root/platform/templates /root/platform/molecule-driver
      cd /root/platform

      cat > templates/agent.conf.j2 <<'J2'
      # Managed by Ansible.
      port=9100
      collector=https://collector.internal:8443
      J2

      cat > nodeagent.yml <<'YML'
      - name: Set up the node agent
        hosts: localhost
        connection: local
        gather_facts: false
        tasks:
          - name: Agent config
            ansible.builtin.template:
              src: templates/agent.conf.j2
              dest: /etc/nodeagent/agent.conf
              owner: root
              group: nodeagent
              mode: "0640"

          - name: Agent queue directory
            ansible.builtin.file:
              path: /srv/nodeagent
              state: directory
              owner: nodeagent
              group: nodeagent
              mode: "0750"

          - name: Record the install
            ansible.builtin.shell: echo "installed $(date +%F)" >> /var/log/nodeagent-install.log
      YML

      # The platform team's molecule driver for this box: each instance is a
      # chroot holding a fresh copy of a stock debian:trixie-slim filesystem.
      cat > molecule-driver/create.yml <<'YML'
      - name: Create
        hosts: localhost
        gather_facts: false
        tasks:
          - name: Give each instance a fresh copy of the clean rootfs
            ansible.builtin.shell: |
              rm -rf /var/lib/molecule-instances/{{ item.name }}
              mkdir -p /var/lib/molecule-instances
              cp -a /opt/molecule-target /var/lib/molecule-instances/{{ item.name }}
            loop: "{{ molecule_yml.platforms }}"
            changed_when: true

          - name: Tell molecule how to reach them
            ansible.builtin.copy:
              dest: "{{ molecule_instance_config }}"
              mode: "0644"
              content: |
                {% for p in molecule_yml.platforms %}
                - instance: {{ p.name }}
                  address: /var/lib/molecule-instances/{{ p.name }}
                  connection: community.general.chroot
                {% endfor %}
      YML

      cat > molecule-driver/destroy.yml <<'YML'
      - name: Destroy
        hosts: localhost
        gather_facts: false
        tasks:
          - name: Remove the instances
            ansible.builtin.file:
              path: "/var/lib/molecule-instances/{{ item.name }}"
              state: absent
            loop: "{{ molecule_yml.platforms }}"

          - name: Forget them
            ansible.builtin.copy:
              dest: "{{ molecule_instance_config }}"
              mode: "0644"
              content: "[]\n"
      YML

      ansible-playbook nodeagent.yml >/dev/null
      echo "scenario ready: /root/platform/nodeagent.yml works on this box and nowhere else"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 480
    run: |
      role=/root/platform/roles/nodeagent
      work=/root/.verify-roles
      target=/var/lib/devopslings-verify/target

      rm -rf "$work" "$target"
      trap 'rm -rf "$work" "$target"' EXIT
      install -d "$work" "$(dirname "$target")"

      if [ ! -f "$role/tasks/main.yml" ]; then
        echo "not yet: there is no role at $role (expected $role/tasks/main.yml)"
        exit 1
      fi
      if [ ! -f "$role/defaults/main.yml" ]; then
        echo "not yet: $role has no defaults/main.yml"
        echo "         a role someone else can reuse states its tunables there, so a"
        echo "         caller can override them from inventory."
        exit 1
      fi
      if [ ! -f "$role/molecule/default/molecule.yml" ]; then
        echo "not yet: $role has no molecule scenario (molecule/default/molecule.yml)"
        exit 1
      fi

      # In the target: run a command inside the chroot, so names resolve
      # against its own /etc/passwd.
      in_target() { chroot "$target" "$@" 2>/dev/null || true; }
      changed_of() { sed -n 's/^verify-target *:.*changed=\([0-9]*\).*/\1/p' "$1" | tail -1; }
      converge() {
        set +e
        ANSIBLE_ROLES_PATH=/nonexistent ansible-playbook -i "$work/inventory" "$work/converge.yml" > "$1" 2>&1
        rc=$?
        set -e
      }
      fresh_target() {
        rm -rf "$target"
        cp -a /opt/molecule-target "$target"
      }

      printf '%s\n' '- hosts: all' '  gather_facts: false' '  roles:' "    - role: $role" > "$work/converge.yml"
      printf '%s\n' '[t]' "verify-target ansible_connection=community.general.chroot ansible_host=$target ansible_python_interpreter=/usr/bin/python3" > "$work/inventory"

      # 1. The role alone, defaults only, on a stock Debian filesystem.
      fresh_target
      converge "$work/run1.out"
      if [ "$rc" -ne 0 ]; then
        echo "not yet: the role failed on a clean Debian target with only its defaults"
        grep -E '^(TASK \[|fatal:|\[ERROR\])' "$work/run1.out" | grep -B1 -E '^(fatal:|\[ERROR\])' \
          | grep -v '^--$' | head -4 | cut -c1-200 | sed 's/^/           /' || true
        echo "         a clean host has no nodeagent user and no /etc/nodeagent. Whatever"
        echo "         the role needs, it has to create."
        exit 1
      fi
      conf=$(in_target cat /etc/nodeagent/agent.conf)
      for want in "port=9100" "collector=https://collector.internal:8443"; do
        if ! printf '%s\n' "$conf" | grep -qxF "$want"; then
          echo "not yet: on a clean target with defaults, /etc/nodeagent/agent.conf has no line '$want'"
          printf '%s\n' "$conf" | head -5 | sed 's/^/           /'
          exit 1
        fi
      done
      if [ -z "$(in_target getent passwd nodeagent)" ]; then
        echo "not yet: on a clean target the role did not create the nodeagent user"
        exit 1
      fi
      got=$(in_target stat -c '%U:%G %a' /etc/nodeagent/agent.conf)
      if [ "$got" != "root:nodeagent 640" ]; then
        echo "not yet: agent.conf on a clean target is '${got:-missing}', expected 'root:nodeagent 640'"
        exit 1
      fi
      got=$(in_target stat -c '%U:%G' /srv/nodeagent)
      if [ "$got" != "nodeagent:nodeagent" ]; then
        echo "not yet: /srv/nodeagent on a clean target is '${got:-missing}', expected owned by nodeagent:nodeagent"
        exit 1
      fi

      # 2. Converged twice, the second run must change nothing.
      converge "$work/run2.out"
      changed=$(changed_of "$work/run2.out")
      if [ "$rc" -ne 0 ] || [ "${changed:-x}" != 0 ]; then
        echo "not yet: a second run of the role on the same target reported changed=${changed:-?} (rc=$rc)"
        grep -E '^changed:' "$work/run2.out" -B2 | grep '^TASK' | head -5 | sed 's/^/           /' || true
        echo "         a role that changes something on every run cannot tell you it converged."
        exit 1
      fi

      # 3. Inventory overrides beat role defaults, and nothing else should.
      fresh_target
      printf '%s\n' '[t]' "verify-target ansible_connection=community.general.chroot ansible_host=$target ansible_python_interpreter=/usr/bin/python3 nodeagent_port=9555 nodeagent_collector=https://collector.example.test:9443" > "$work/inventory"
      converge "$work/run3.out"
      conf=$(in_target cat /etc/nodeagent/agent.conf)
      if [ "$rc" -ne 0 ] || ! printf '%s\n' "$conf" | grep -qxF "port=9555" \
         || ! printf '%s\n' "$conf" | grep -qxF "collector=https://collector.example.test:9443"; then
        echo "not yet: with nodeagent_port=9555 and nodeagent_collector set in inventory, agent.conf says:"
        printf '%s\n' "$conf" | head -5 | sed 's/^/           /'
        echo "         the template has to use the variables, and they have to live in"
        echo "         defaults/main.yml: vars/main.yml outranks inventory, so a caller"
        echo "         could never override them."
        exit 1
      fi

      # 4. The student's own scenario. A private mount namespace lets the
      # check shadow files without ever modifying them on disk: a tmpfs over
      # the box's /etc/nodeagent catches a scenario that converges the box
      # itself instead of a clean target.
      molecule_run() {
        set +e
        rm -f "$2" "$2.rc" "$2.box" "$2.done"
        unshare --mount --propagation private bash -c '
          set -e
          mkdir -p /etc/nodeagent
          mount -t tmpfs tmpfs /etc/nodeagent
          if [ -n "$2" ]; then mount --bind "$2" "$1/tasks/main.yml"; fi
          cd "$1"
          molecule test > "$3" 2>&1 || echo "rc=$?" >> "$3.rc"
          if [ -n "$(ls -A /etc/nodeagent)" ]; then echo touched > "$3.box"; fi
          touch "$3.done"
        ' _ "$role" "$1" "$2"
        set -e
        if [ ! -e "$2.done" ]; then
          echo "not yet: the check could not run molecule in an isolated mount namespace"
          echo "         this is the grader failing, not your role. Reset the lesson and retry."
          exit 1
        fi
      }
      molecule_failed() {
        grep -E 'Executed: Failed|^CRITICAL|^ERROR' "$1" | head -4 | cut -c1-200 | sed 's/^/           /' || true
      }

      molecule_run "" "$work/mol.out"
      if [ -e "$work/mol.out.box" ]; then
        echo "not yet: your molecule scenario wrote to this box's own /etc/nodeagent"
        echo "         the box already has the hand-made user and directory, so a test"
        echo "         run here proves nothing. Use the chroot driver in"
        echo "         /root/platform/molecule-driver so each run starts from a clean target."
        exit 1
      fi
      if [ -e "$work/mol.out.rc" ]; then
        echo "not yet: 'molecule test' in $role failed"
        molecule_failed "$work/mol.out"
        exit 1
      fi

      # 5. The same scenario against a role that does nothing must fail,
      # or the scenario is not testing the role.
      printf '[]\n' > "$work/empty.yml"
      molecule_run "$work/empty.yml" "$work/sab.out"
      if [ ! -e "$work/sab.out.rc" ]; then
        echo "not yet: 'molecule test' still passes when the role's tasks/main.yml is empty"
        echo "         converge and idempotence pass trivially on a role that does"
        echo "         nothing. The verify step has to check what the role is for: the"
        echo "         config file and its contents, the user, the directories."
        exit 1
      fi

      echo "PASS: the role converges a clean target from defaults, is idempotent, takes"
      echo "      overrides from inventory, and its molecule scenario catches a broken role."
---
