---
kind: lesson
title: "you added them to the group and it still says permission denied"
description: |
  dana is in the deploy group. `id dana` says so. dana's shell says permission
  denied. Both are telling the truth, because group membership is granted at
  login and a process that was already running never hears about it.
name: users-groups-sudoers
slug: users-groups-sudoers
createdAt: "2026-08-03"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      install -d /root/answers /var/lib/devopslings /srv/deploy

      groupadd -f deploy
      id -u dana >/dev/null 2>&1 || useradd --create-home --shell /bin/bash dana

      # dana was added to the group after their session started, which is the
      # entire scenario. The membership is real and their running shell has an
      # older credential set that does not include it.
      usermod -aG deploy dana

      chgrp deploy /srv/deploy
      chmod 0770 /srv/deploy
      printf 'release=2026.08.03\nchannel=stable\n' > /srv/deploy/manifest.env
      chgrp deploy /srv/deploy/manifest.env
      chmod 0660 /srv/deploy/manifest.env

      # A long-running login shell for dana, started BEFORE the usermod above
      # would have taken effect for it. This is the session that cannot read
      # the file — it is what a student would be looking at over dana's
      # shoulder.
      cat > /etc/systemd/system/dana-session.service <<'UNIT'
      [Unit]
      Description=dana's login session (simulated)

      [Service]
      User=dana
      Group=dana
      ExecStart=/bin/bash -c 'while :; do sleep 3600; done'
      Restart=no
      UNIT
      systemctl daemon-reload
      systemctl start dana-session.service >/dev/null 2>&1 || true

      # deploy-status needs root to read the fleet table, and dana is supposed
      # to be able to run just that one command. Nobody has set that up.
      cat > /usr/local/bin/deploy-status <<'SH'
      #!/bin/bash
      set -euo pipefail
      if [ "$(id -u)" -ne 0 ]; then
        echo "deploy-status: must run as root" >&2
        exit 1
      fi
      echo "fleet: 12 hosts, 12 on release 2026.08.03"
      SH
      chmod 0750 /usr/local/bin/deploy-status

      rm -f /etc/sudoers.d/dana

      echo session > /var/lib/devopslings/users-groups.why

      cat > /root/questions.txt <<'Q'
      dana is in the deploy group, and dana's shell still gets permission denied
      reading /srv/deploy/manifest.env.

        /root/answers/why    why the running shell does not have the group. One of:

                               session   the process's credentials were fixed at login
                               cache     a name-service cache needs flushing
                               secondary secondary groups do not grant file access
                               relabel   the file needs its group ownership changed

      Then, without changing any permissions on /srv/deploy or its contents:

        1. make dana able to read /srv/deploy/manifest.env in a NEW login session
        2. let dana run /usr/local/bin/deploy-status as root via sudo, and
           nothing else as root
      Q

      echo "scenario ready — dana is in deploy, and dana's running shell disagrees"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      want_why=$(cat /var/lib/devopslings/users-groups.why)

      if [ ! -s /root/answers/why ]; then
        echo "not yet: /root/answers/why is missing or empty"
        echo "         one of: session, cache, secondary, relabel"
        exit 1
      fi
      got=$(tr -d '[:space:]' < /root/answers/why | tr 'A-Z' 'a-z')
      if [ "$got" != "$want_why" ]; then
        case "$got" in
          cache)
            echo "not yet: there is no nscd or sssd on this box — 'id dana' already reports"
            echo "         the group correctly, so nothing is stale in a lookup cache."
            ;;
          secondary)
            echo "not yet: secondary groups grant file access exactly like the primary one."
            echo "         A NEW shell for dana can read the file right now; the running"
            echo "         one cannot. Same user, same groups on paper, different result."
            ;;
          relabel)
            echo "not yet: /srv/deploy/manifest.env is already group deploy, mode 0660."
            echo "         The file is set up correctly — the question is why one of dana's"
            echo "         processes does not benefit from it."
            ;;
          *)
            echo "not yet: '$got' is not one of session, cache, secondary, relabel"
            ;;
        esac
        exit 1
      fi

      # The permissions must not have been touched — the point is that they were
      # right all along.
      dmode=$(stat -c %a /srv/deploy)
      fmode=$(stat -c %a /srv/deploy/manifest.env)
      fgrp=$(stat -c %G /srv/deploy/manifest.env)
      if [ "$dmode" != "770" ] || [ "$fmode" != "660" ] || [ "$fgrp" != "deploy" ]; then
        echo "not yet: /srv/deploy is now $dmode and manifest.env is $fmode group $fgrp"
        echo "         they started as 770 and 660 group deploy, which was already correct."
        echo "         Reset the lesson and fix the session, not the file."
        exit 1
      fi

      # A fresh login session picks up the group. `su -` allocates one, which is
      # exactly the thing dana's old shell never did.
      if ! su - dana -c 'cat /srv/deploy/manifest.env' >/dev/null 2>&1; then
        echo "not yet: a fresh login session for dana still cannot read the manifest"
        echo "         check that dana is actually in the deploy group: id dana"
        exit 1
      fi

      # sudo: the one command, as root, and nothing more.
      if ! su - dana -c 'sudo -n /usr/local/bin/deploy-status' >/dev/null 2>&1; then
        echo "not yet: dana cannot run deploy-status via sudo without a password"
        echo "         (the check runs it non-interactively, so it needs NOPASSWD)"
        exit 1
      fi

      if su - dana -c 'sudo -n /bin/bash -c id' >/dev/null 2>&1; then
        echo "not yet: dana can run an arbitrary root shell via sudo"
        echo "         the grant is meant to be one command, not ALL."
        exit 1
      fi
      if su - dana -c 'sudo -n /bin/cat /etc/shadow' >/dev/null 2>&1; then
        echo "not yet: dana can read /etc/shadow via sudo — the grant is too wide."
        exit 1
      fi

      echo "PASS — the group was right all along; a new session sees it, and dana can run"
      echo "       exactly one command as root."
---
