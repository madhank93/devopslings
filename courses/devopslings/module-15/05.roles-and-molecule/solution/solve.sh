#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/platform

r=roles/nodeagent
mkdir -p $r/defaults $r/tasks $r/templates $r/molecule/default

cat > $r/defaults/main.yml <<'YML'
nodeagent_port: 9100
nodeagent_collector: https://collector.internal:8443
YML

# Everything the old playbook found already on the box, the role now creates.
cat > $r/tasks/main.yml <<'YML'
- name: Agent group
  ansible.builtin.group:
    name: nodeagent
    system: true

- name: Agent user
  ansible.builtin.user:
    name: nodeagent
    group: nodeagent
    system: true
    create_home: false
    shell: /usr/sbin/nologin

- name: Agent config directory
  ansible.builtin.file:
    path: /etc/nodeagent
    state: directory
    owner: root
    group: nodeagent
    mode: "0750"

- name: Agent config
  ansible.builtin.template:
    src: agent.conf.j2
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
YML

cat > $r/templates/agent.conf.j2 <<'J2'
# Managed by Ansible.
port={{ nodeagent_port }}
collector={{ nodeagent_collector }}
J2

cp molecule-driver/create.yml molecule-driver/destroy.yml $r/molecule/default/

cat > $r/molecule/default/molecule.yml <<'YML'
driver:
  name: default
platforms:
  - name: nodeagent-clean
provisioner:
  name: ansible
YML

cat > $r/molecule/default/converge.yml <<'YML'
- name: Converge
  hosts: all
  gather_facts: false
  tasks:
    - name: Apply the role under test
      ansible.builtin.include_role:
        name: "{{ lookup('env', 'MOLECULE_PROJECT_DIRECTORY') }}"
YML

cat > $r/molecule/default/verify.yml <<'YML'
- name: Verify
  hosts: all
  gather_facts: false
  tasks:
    - name: Read the config
      ansible.builtin.slurp:
        src: /etc/nodeagent/agent.conf
      register: conf

    - name: Config carries the defaults
      ansible.builtin.assert:
        that:
          - "'port=9100' in (conf.content | b64decode).splitlines()"
          - "'collector=https://collector.internal:8443' in (conf.content | b64decode).splitlines()"

    - name: Look up the agent user
      ansible.builtin.getent:
        database: passwd
        key: nodeagent

    - name: Stat the queue directory
      ansible.builtin.stat:
        path: /srv/nodeagent
      register: queue

    - name: Queue directory belongs to the agent
      ansible.builtin.assert:
        that:
          - queue.stat.isdir
          - queue.stat.pw_name == 'nodeagent'
YML

cat > nodeagent.yml <<'YML'
- name: Set up the node agent
  hosts: localhost
  connection: local
  gather_facts: false
  roles:
    - role: roles/nodeagent
YML

cd $r && molecule test
