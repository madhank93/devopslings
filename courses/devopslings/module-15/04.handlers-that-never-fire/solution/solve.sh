#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail
cd /root/ansible

# The task asked for a file that does not exist under that name. Its failure
# ended the play before the handler phase.
mv files/ratelimiter-logrotate files/ratelimiter.logrotate

# A handler that asks for "started" does nothing to a running service.
# force_handlers makes a later failure in the play no longer swallow a pending
# restart.
cat > site.yml <<'YML'
- name: Configure the edge rate limiter
  hosts: edge
  gather_facts: false
  force_handlers: true
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
        state: restarted
YML

# The notification lost in the failed run is gone for good: the template task
# now reports "ok", so restart once by hand to load what is already on disk.
systemctl restart ratelimiter.service
ansible-playbook site.yml
