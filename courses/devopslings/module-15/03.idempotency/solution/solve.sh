#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/agent

# The whole config lives in one file owned by one task, so no two tasks fight.
sed -i 's/^max_conn = 256$/max_conn = 512/' files/agent.conf

# The timestamp changes every render; the file says who manages it, not when.
sed -i '1s/.*/# Managed by Ansible./' templates/agent.env.j2

cat > site.yml <<'YML'
- name: fleet-agent is installed and configured
  hosts: agents
  tasks:
    - name: service account exists
      ansible.builtin.user:
        name: fleetagent
        system: true
        create_home: false
        shell: /usr/sbin/nologin

    - name: agent binary is installed
      ansible.builtin.copy:
        src: fleet-agent
        dest: /usr/local/bin/fleet-agent
        mode: "0755"

    - name: config directory exists
      ansible.builtin.file:
        path: /etc/fleet-agent
        state: directory
        mode: "0755"

    - name: config is in place
      ansible.builtin.copy:
        src: agent.conf
        dest: /etc/fleet-agent/agent.conf
        mode: "0644"

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
        access_time: preserve
        modification_time: preserve
YML

ansible-playbook site.yml
