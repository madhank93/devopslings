---
kind: lesson
title: "the playbook that works on the box it was written on"
description: |
  Write the playbook that takes a bare box to nginx serving the fleet status
  page. The grader does not run it on your box. It wipes nginx, the page and
  apt's package lists, then runs it once, the way a brand-new machine would
  meet it. Anything you did by hand while developing it is gone.
name: the-playbook
slug: the-playbook
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

      # A bare box: no nginx, no package lists, nothing from an earlier attempt.
      systemctl stop nginx.service >/dev/null 2>&1 || true
      apt-get purge -y -qq nginx nginx-common >/dev/null 2>&1 || true
      rm -rf /etc/nginx /srv/www /var/www /var/log/nginx /var/lib/apt/lists/*
      # apt's cache_valid_time trusts these timestamps, so a fresh box has to
      # look like nothing ever updated it.
      rm -f /var/lib/apt/periodic/update-success-stamp /var/cache/apt/*.bin
      touch -d 2000-01-01 /var/lib/apt/lists

      # The fleet has no route to the internet; the image's local mirror is its
      # only package source. That also makes grading independent of the network.
      if [ -f /etc/apt/sources.list.d/debian.sources ]; then
        mv /etc/apt/sources.list.d/debian.sources /var/lib/devopslings/debian.sources
      fi

      rm -rf /root/site
      install -d /root/site/files
      cd /root/site
      cat > ansible.cfg <<'CFG'
      [defaults]
      inventory = inventory.ini
      interpreter_python = /usr/bin/python3
      CFG
      cat > inventory.ini <<'INV'
      [web]
      box ansible_connection=local
      INV
      cat > files/index.html <<'HTML'
      <!doctype html>
      <title>fleet status</title>
      <h1>fleet status: ok</h1>
      <p>Served by the web tier, configured by Ansible.</p>
      HTML
      cp files/index.html /var/lib/devopslings/the-playbook.index.html

      cat > README <<'TXT'
      Write site.yml in this directory. One run of

          ansible-playbook site.yml

      on a box that has never had nginx must leave:

        - nginx installed from the box's package source, running, and enabled
        - files/index.html served at http://127.0.0.1/ (port 80)
        - the document root at /srv/www
        - nginx's stock welcome site no longer answering on port 80

      The box has no internet access. apt's only source is a local mirror,
      which is already configured.
      TXT

      echo "scenario ready — /root/site is waiting for a site.yml"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      if ! cd /root/site 2>/dev/null; then
        echo "not yet: /root/site is gone — reset the lesson to get it back"
        exit 1
      fi
      if [ ! -f site.yml ]; then
        echo "not yet: there is no /root/site/site.yml yet"
        exit 1
      fi
      export ANSIBLE_NOCOLOR=1 ANSIBLE_STDOUT_CALLBACK=default ANSIBLE_DEPRECATION_WARNINGS=False

      if ! syntax=$(ansible-playbook --syntax-check site.yml 2>&1); then
        echo "not yet: site.yml does not parse:"
        tail -n 6 <<<"$syntax" | sed 's/^/         /'
        exit 1
      fi

      # Grade a single run on a clean box, so a playbook that only works because
      # of something done by hand on this one fails here as it would on a new
      # machine. Every check therefore starts from the same state.
      systemctl stop nginx.service >/dev/null 2>&1 || true
      systemctl reset-failed nginx.service >/dev/null 2>&1 || true
      apt-get purge -y -qq nginx nginx-common >/dev/null 2>&1 || true
      rm -rf /etc/nginx /srv/www /var/www /var/log/nginx /var/lib/apt/lists/*
      rm -f /var/lib/apt/periodic/update-success-stamp /var/cache/apt/*.bin
      touch -d 2000-01-01 /var/lib/apt/lists

      # A new box gets /root/site and nothing else from this one, so the run
      # sees the rest of /root as empty.
      rc=0
      run=$(unshare -m sh -c '
        m=$(mktemp -d)
        mount --bind /root/site "$m" && mount -t tmpfs tmpfs /root \
          && mkdir /root/site && mount --move "$m" /root/site || exit 99
        rmdir "$m"
        cd /root/site && ansible-playbook site.yml' 2>&1) || rc=$?
      if grep -q 'no hosts matched' <<<"$run"; then
        echo "not yet: site.yml's hosts: line matches nothing in inventory.ini — the box is 'box', in group 'web'"
        exit 1
      fi
      if [ "$rc" != 0 ]; then
        task=$(awk '/^TASK \[/{t=$0; sub(/ \*+$/, "", t)} /^(fatal|failed):/{print t; exit}' <<<"$run")
        echo "not yet: on a clean box the run failed${task:+ at $task}"
        grep -m1 -E '^(fatal|failed):' <<<"$run" | cut -c1-240 | sed 's/^/         /' || true
        if grep -q "No package matching 'nginx'" <<<"$run"; then
          echo "         A new box has no apt package lists, so apt cannot see nginx until"
          echo "         something fetches the index from the mirror."
        fi
        if grep -E '^(fatal|failed):' <<<"$run" | grep -E '/root/' | grep -vqE '/root/site(/|\b)'; then
          echo "         The run sees only /root/site from this box; the rest of /root is"
          echo "         empty, as it would be on a new machine."
        fi
        exit 1
      fi

      # The lesson is modules that describe state; a command that installs
      # nginx cannot report whether it changed anything.
      if ! grep -rqE '^[[:space:]]*(-[[:space:]]+)?(ansible\.(builtin|legacy)\.)?(apt|package):' \
           --include='*.yml' --include='*.yaml' /root/site; then
        echo "not yet: the run worked, but nothing in /root/site uses the apt (or package)"
        echo "         module, so nginx is installed by a command. Describe the state with"
        echo "         ansible.builtin.apt instead."
        exit 1
      fi
      if ! dpkg-query -W -f='${Status}' nginx 2>/dev/null | grep -q 'install ok installed'; then
        echo "not yet: the run succeeded, but nginx is not installed afterwards"
        exit 1
      fi
      if ! systemctl is-active --quiet nginx.service; then
        if systemctl is-failed --quiet nginx.service; then
          echo "not yet: nginx is installed but failed to start:"
          nginx -t 2>&1 | tail -n 3 | sed 's/^/         /' || true
        else
          echo "not yet: nginx is installed but not running after the run"
          echo "         installing a package on this box does not start its service, and the"
          echo "         playbook did not leave it running"
        fi
        exit 1
      fi
      if ! systemctl is-enabled --quiet nginx.service; then
        echo "not yet: nginx is running but not enabled — it will not come back after a reboot"
        exit 1
      fi

      page=/var/lib/devopslings/the-playbook.served
      code=$(curl -s -o "$page" -w '%{http_code}' --max-time 5 http://127.0.0.1/ || true)
      roots=$(nginx -T 2>/dev/null | grep -v '^\s*#' | grep -oE '\broot\s+[^;]+' | awk '{print $2}' | sort -u | paste -sd' ' || true)
      if [ "$code" = 000 ]; then
        ports=$(ss -ltnpH 2>/dev/null | grep nginx | awk '{print $4}' | tr '\n' ' ' || true)
        echo "not yet: nothing answers on port 80; nginx is listening on: ${ports:-nothing}"
        exit 1
      fi
      who80=$(ss -ltnpH 'sport = :80' 2>/dev/null | grep -oE 'users:\(\("[^"]+"' | cut -d'"' -f2 | sort -u | paste -sd' ' || true)
      if [ "$who80" != nginx ]; then
        echo "not yet: port 80 answers, but the process listening there is '${who80:-unknown}', not nginx"
        exit 1
      fi
      if grep -q 'Welcome to nginx' "$page"; then
        if [ -e /etc/nginx/sites-enabled/default ]; then
          echo "not yet: port 80 serves nginx's stock welcome page"
          echo "         /etc/nginx/sites-enabled/default is still enabled, and its listen line"
          echo "         says default_server, so it answers port 80 ahead of your site"
        elif grep -q '/srv/www' <<<"$roots"; then
          echo "not yet: port 80 serves nginx's stock welcome page, but the config on disk"
          echo "         points at /srv/www — the running nginx never loaded that config"
        else
          echo "not yet: port 80 serves nginx's stock welcome page; no server block serves /srv/www"
        fi
        exit 1
      fi
      if [ "$code" != 200 ]; then
        echo "not yet: port 80 answers HTTP $code for /"
        if [ ! -f /srv/www/index.html ]; then
          echo "         /srv/www/index.html does not exist after a clean run, so nothing in"
          echo "         the playbook puts it there"
        else
          echo "         nginx's root directives: ${roots:-none}"
        fi
        exit 1
      fi
      if ! cmp -s "$page" /var/lib/devopslings/the-playbook.index.html; then
        echo "not yet: port 80 serves a page, but not files/index.html. It starts:"
        head -n 3 "$page" | sed 's/^/           /'
        echo "         nginx's root directives: ${roots:-none}"
        exit 1
      fi
      # The same bytes can come from another copy of the page, so change the one
      # in /srv/www and see whether port 80 follows. The page is put back after.
      doc=/srv/www/index.html
      if [ ! -f "$doc" ]; then
        echo "not yet: the page is right, but $doc does not exist; nginx serves it from ${roots:-somewhere else}"
        exit 1
      fi
      marker="devopslings-$(date +%s%N)"
      cp -p "$doc" "$doc.devopslings"
      printf '%s\n' "$marker" >> "$doc"
      seen=$(curl -s --max-time 5 http://127.0.0.1/ || true)
      cp -p "$doc.devopslings" "$doc"
      rm -f "$doc.devopslings"
      if ! grep -qF "$marker" <<<"$seen"; then
        echo "not yet: the page is right, but it does not come from $doc: a line added"
        echo "         there did not show up at http://127.0.0.1/"
        echo "         nginx's root directives: ${roots:-none}"
        exit 1
      fi

      echo "PASS — one run on a clean box installs nginx, starts and enables it, and serves the status page from /srv/www."
---
