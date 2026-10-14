---
title: "the playbook that works on the box it was written on"
---

## The situation

The web tier needs nginx serving a status page, and the next twenty boxes will
be built from a playbook rather than by hand. `/root/site` has everything except
the playbook:

```
$ cd /root/site && ls
README  ansible.cfg  files  inventory.ini
$ cat inventory.ini
[web]
box ansible_connection=local
```

Writing a playbook that passes on your own box is easy. You run it, something
fails, you fix it by hand or in the playbook, and you run it again. By the fifth
run it is green. The trouble is that the fifth run started from a box the first
four had already changed, and from whatever you typed into the shell in between.
A new machine gets one run, from nothing.

## Your objectives

Write `/root/site/site.yml`. One run of `ansible-playbook site.yml` on a box
that has never had nginx must leave:

- nginx installed from the box's package source, running, and enabled at boot
- `files/index.html` served at `http://127.0.0.1/`, on port 80
- the document root at `/srv/www`
- nginx's stock welcome site no longer answering on port 80

The box has no internet. apt's only source is a local mirror, and it is already
configured.

## What you're being graded on

The grader does not trust your box. It purges nginx, deletes `/etc/nginx`,
`/srv/www` and apt's package lists, then runs your playbook once. The run must
succeed. nginx must be active and enabled, and `curl http://127.0.0.1/` must
return `files/index.html` byte for byte, served from `/srv/www`.

To see what the grader sees, do the same wipe yourself before a run:

```
systemctl stop nginx; apt-get purge -y nginx nginx-common
rm -rf /etc/nginx /srv/www /var/www /var/lib/apt/lists/*
rm -f /var/lib/apt/periodic/update-success-stamp
```

<details>
<summary>Hint 1 — the shape of a playbook</summary>

A play names the hosts it runs on, and a list of tasks. Each task calls one
module, and each module describes a state, not a command:

```yaml
- name: web tier serves the fleet status page
  hosts: web
  tasks:
    - name: nginx is installed
      ansible.builtin.apt:
        name: nginx
```

Name tasks for the state they leave behind ("nginx is installed"), not for the
action ("install nginx"). The output then reads as a checklist of facts about
the box.

`ansible-doc ansible.builtin.apt` documents every module on the box itself.
No internet needed.

</details>

<details>
<summary>Hint 2 — it worked an hour ago</summary>

`No package matching 'nginx' is available` on a clean box, when the same task
worked on yours, means apt has no package lists. You ran `apt-get update` once
while exploring, so yours has them. A new box does not.

```yaml
      ansible.builtin.apt:
        name: nginx
        update_cache: true
        cache_valid_time: 3600
```

`cache_valid_time` skips the update when the lists are recent, so repeat runs
stay fast.

</details>

<details>
<summary>Hint 3 — "Welcome to nginx!"</summary>

The Debian package ships a site, `/etc/nginx/sites-enabled/default`, whose
`listen` line says `default_server`. For a request that matches no
`server_name`, the default server answers, so your site loses port 80 to it
even when your config is correct. Remove that symlink, and make your own site
the default.

If the default site is gone and the welcome page is still served, nginx is
running a config it loaded before yours existed. Writing a file does not tell a
running process anything. Lesson 04 is about doing that properly.

</details>

<details>
<summary>Solution</summary>

```yaml
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
```

`src: index.html` needs no path. `copy` looks in the `files/` directory next to
the playbook.

### Where it breaks on a new machine

Each of these passes on the box you developed on, and each fails the clean run:

- **No `update_cache`.** Your box has package lists from the one time you ran
  `apt-get update`. A new box has none.
- **A file you made by hand.** A `/srv/www/index.html` you copied while
  exploring is gone after the wipe. nginx answers 403, because the directory
  has nothing to serve.
- **The default site.** It was removed by hand on your box and never by the
  playbook.
- **The service never started.** On this box a package install does not start
  its service, which is common in container images. On a full Debian host it
  does, with the stock config, which is how you get the welcome page.

The test for "it works" is one run on a box with nothing on it, not a run that
finally went green after four others. That is the run the grader does, and it
is the one a new machine gets.

</details>
