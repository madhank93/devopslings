#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

cat > /root/site/site.yml <<'YML'
- name: web tier serves the fleet status page
  hosts: web
  tasks:
    - name: nginx is installed
      ansible.builtin.apt:
        name: nginx
        update_cache: true
        cache_valid_time: 3600

    - name: the stock site is not enabled
      ansible.builtin.file:
        path: /etc/nginx/sites-enabled/default
        state: absent
      notify: reload nginx

    - name: the document root exists
      ansible.builtin.file:
        path: /srv/www
        state: directory
        mode: "0755"

    - name: the status page is in place
      ansible.builtin.copy:
        src: index.html
        dest: /srv/www/index.html
        mode: "0644"

    - name: the site config is in place
      ansible.builtin.copy:
        dest: /etc/nginx/sites-available/fleet
        mode: "0644"
        content: |
          server {
              listen 80 default_server;
              listen [::]:80 default_server;
              root /srv/www;
              index index.html;
          }
      notify: reload nginx

    - name: the site is enabled
      ansible.builtin.file:
        src: /etc/nginx/sites-available/fleet
        dest: /etc/nginx/sites-enabled/fleet
        state: link
      notify: reload nginx

    - name: nginx is running and starts at boot
      ansible.builtin.service:
        name: nginx
        state: started
        enabled: true

  handlers:
    - name: reload nginx
      ansible.builtin.service:
        name: nginx
        state: reloaded
YML

cd /root/site
ansible-playbook site.yml
