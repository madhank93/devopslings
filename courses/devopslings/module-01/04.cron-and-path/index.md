---
kind: lesson
title: "the backup runs fine when you run it and writes nothing at 03:17"
description: |
  A nightly backup has not produced a file in three weeks, and the script works
  perfectly every time a human runs it. cron hands your script a different
  `PATH`, a different shell and no terminal — and sends the error to a mailbox
  nobody reads. Make the job survive being run by something other than you.
name: cron-and-path
slug: cron-and-path
createdAt: "2026-08-02"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      install -d /srv/checkout /var/backups/checkout /opt/backup/bin

      # The data the backup is supposed to protect.
      printf 'id,customer,total\n1,acme,42.00\n2,globex,17.50\n' > /srv/checkout/orders.csv
      printf 'schema_version=7\n' > /srv/checkout/meta.conf

      # The backup tool the platform team ships. It lives outside the default
      # PATH, which is the whole point: an interactive login finds it, and a
      # non-login, non-interactive shell does not.
      cat > /opt/backup/bin/snapshot <<'SH'
      #!/bin/bash
      set -euo pipefail
      src=${1:?usage: snapshot <src-dir> <dest-dir>}
      dest=${2:?usage: snapshot <src-dir> <dest-dir>}
      [ -d "$src" ] || { echo "snapshot: no such directory: $src" >&2; exit 2; }
      install -d "$dest"
      out="$dest/checkout-$(date -u +%Y%m%dT%H%M%S).tar.gz"
      tar -czf "$out" -C "$src" .
      echo "snapshot: wrote $out ($(stat -c%s "$out") bytes)"
      SH
      chmod +x /opt/backup/bin/snapshot

      # How /opt/backup/bin gets onto a human's PATH. Login shells read
      # profile.d; interactive shells read bash.bashrc. cron's shell reads
      # neither, which is why "it works when I run it" is true and useless.
      cat > /etc/profile.d/backup-tools.sh <<'SH'
      # The backup tooling is not in the default PATH.
      export PATH="$PATH:/opt/backup/bin"
      SH
      if ! grep -q backup-tools /etc/bash.bashrc; then
        cat >> /etc/bash.bashrc <<'SH'
      [ -r /etc/profile.d/backup-tools.sh ] && . /etc/profile.d/backup-tools.sh
      SH
      fi

      # The job itself, as the person who wrote it left it: no PATH of its own,
      # because on their terminal it did not need one.
      cat > /usr/local/bin/nightly-backup.sh <<'SH'
      #!/bin/bash
      set -euo pipefail

      echo "[$(date -Is)] nightly-backup starting"
      snapshot /srv/checkout /var/backups/checkout
      echo "[$(date -Is)] nightly-backup finished"
      SH
      chmod +x /usr/local/bin/nightly-backup.sh

      # The crontab, written the way it would be written by someone who has
      # only ever tested the command in a shell.
      crontab - <<'CRON'
      17 3 * * * /usr/local/bin/nightly-backup.sh >> /var/log/nightly-backup-$(date +%Y-%m-%d).log 2>&1
      CRON

      # Evidence of the last backup that did work, three weeks ago.
      tar -czf /var/backups/checkout/checkout-20260712T031702.tar.gz -C /srv/checkout .
      touch -d '2026-07-12 03:17:02' /var/backups/checkout/checkout-20260712T031702.tar.gz

      systemctl enable --now cron.service >/dev/null 2>&1
      for _ in $(seq 30); do
        systemctl is-active --quiet cron.service && break
        sleep 1
      done

      # Give the student last night's attempt to look at. Nothing here waits
      # until 03:17: this is the same command line, run by the same cron, once,
      # so the journal carries a real record of what actually happened rather
      # than a story about it.
      printf '* * * * * root %s\n' \
        '/usr/local/bin/nightly-backup.sh >> /var/log/nightly-backup-$(date +%Y-%m-%d).log 2>&1' \
        > /etc/cron.d/devopslings-lastnight
      chmod 0644 /etc/cron.d/devopslings-lastnight
      for _ in $(seq 100); do
        journalctl -u cron.service --since '-3 min' > /tmp/cron.journal 2>/dev/null || true
        if grep -q 'nightly-backup' /tmp/cron.journal; then break; fi
        sleep 1
      done
      rm -f /etc/cron.d/devopslings-lastnight

      echo "scenario ready — last backup: $(ls -1 /var/backups/checkout | tail -1)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      # The check runs the student's crontab line through the real cron, on a
      # schedule it controls, and grades what the job leaves behind. Anything
      # that only works when a human types it will fail here for exactly the
      # reason the lesson is about.
      cleanup() { rm -f /etc/cron.d/devopslings-verify; }
      trap cleanup EXIT

      if ! crontab -l > /tmp/crontab.check 2>/dev/null; then
        echo "not yet: root has no crontab — the backup is still supposed to be a cron job"
        exit 1
      fi

      job=$(grep -v '^[[:space:]]*#' /tmp/crontab.check | grep 'nightly-backup' | grep -vE '^[A-Za-z_][A-Za-z0-9_]*=' | head -1) || true
      if [ -z "$job" ]; then
        echo "not yet: no crontab line runs nightly-backup any more"
        exit 1
      fi

      sched=$(echo "$job" | awk '{print $1, $2, $3, $4, $5}')
      if [ "$sched" != "17 3 * * *" ]; then
        echo "not yet: the schedule is '$sched' — leave it at '17 3 * * *'. The check runs the job for you; making it run more often is not the fix."
        exit 1
      fi

      # Everything after the five schedule fields, byte for byte: any escaping
      # the student added has to survive into the file cron reads.
      cmd=$(echo "$job" | sed -E 's/^[[:space:]]*([^[:space:]]+[[:space:]]+){5}//')

      # Environment assignments at the top of a crontab apply to its jobs, so
      # they come along — setting PATH there is a legitimate fix.
      envs=$(grep -E '^[A-Za-z_][A-Za-z0-9_]*=' /tmp/crontab.check) || true

      # Grade the cron run, not a run the student did by hand five minutes ago.
      rm -f /var/backups/checkout/*.tar.gz
      rm -f /var/log/nightly-backup-*.log

      { if [ -n "$envs" ]; then printf '%s\n' "$envs"; fi
        printf '* * * * * root %s\n' "$cmd"; } > /etc/cron.d/devopslings-verify
      chmod 0644 /etc/cron.d/devopslings-verify

      found=""
      for _ in $(seq 150); do
        found=$(ls -1t /var/backups/checkout/*.tar.gz 2>/dev/null | head -1) || true
        [ -n "$found" ] && break
        sleep 1
      done
      cleanup

      log=$(ls -1t /var/log/nightly-backup-????-??-??.log 2>/dev/null | head -1) || true

      if [ -z "$found" ]; then
        echo "not yet: cron ran the job and /var/backups/checkout is still empty"
        if [ -n "$log" ]; then
          echo "the job's own log says:"
          tail -3 "$log"
        else
          echo "and nothing reached /var/log/nightly-backup-<date>.log either — the job's output is still going somewhere no human reads"
        fi
        exit 1
      fi

      # Listed into a file rather than piped: `tar | grep -q` dies of SIGPIPE
      # under pipefail and would fail a correct backup.
      tar -tzf "$found" > /tmp/backup.list
      if ! grep -q 'orders.csv' /tmp/backup.list; then
        echo "not yet: $found exists but does not contain the checkout data"
        exit 1
      fi

      if [ -z "$log" ]; then
        echo "not yet: the backup ran but wrote no /var/log/nightly-backup-<date>.log — when this fails again at 03:17 there will be nothing to read"
        exit 1
      fi
      if [ -z "$(find /var/log -maxdepth 1 -name 'nightly-backup-????-??-??.log' -mmin -5)" ]; then
        echo "not yet: $log is stale — this cron run did not write to it"
        exit 1
      fi
      if ! grep -q 'finished' "$log"; then
        echo "not yet: $log has no 'finished' line — the job started under cron and did not get to the end"
        echo "the job's own log says:"
        tail -3 "$log"
        exit 1
      fi

      echo "PASS — cron ran the job on its own schedule, the backup landed in $found, and the run is logged in $log."
---
