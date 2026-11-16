---
kind: lesson
title: "3-2-1, and a copy the attacker cannot delete"
description: |
  Ransomware crews delete the backups before they encrypt anything. The
  shop's backups sit on the machine they protect, written with credentials
  that machine holds. Add an off-site copy that survives an attacker who has
  everything the backup job has.
name: 3-2-1-and-immutable
slug: 3-2-1-and-immutable
createdAt: "2026-11-13"

sandbox:
  stack: ha-stack
  service: ops

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      ha-reset
      # An empty off-site repository server, started with no options.
      docker exec devopslings-ha-backupd sh -c 'rm -rf /data/* /data/.[!.]*' || true
      docker restart devopslings-ha-backupd >/dev/null
      for _ in $(seq 60); do curl -s -o /dev/null --max-time 1 http://backupd:8000/ && break; sleep 0.5; done
      mkdir -p /ha/backups /ha/backupd
      : > /ha/backupd/options
      pw=$(head -c 24 /dev/urandom | base64 | tr -d '/+=')
      cat > /ha/backups/backup.env <<ENV
      # Everything the backup job needs. It lives on ops, so anyone who owns ops has it.
      RESTIC_REPOSITORY=rest:http://backupd:8000/shop
      RESTIC_PASSWORD=$pw
      ENV
      cat > /ha/backups/backup.sh <<'SH'
      #!/bin/bash
      # Nightly backup of the shop database, kept on this machine.
      set -euo pipefail
      set -a; . /ha/backups/backup.env; set +a
      f=/ha/backups/shop-$(date +%s).dump
      pg_dump -Fc -f "$f" shop
      echo "backup written: $f"
      SH
      chmod +x /ha/backups/backup.sh
      /ha/backups/backup.sh >/dev/null
      echo "scenario ready — where the shop's backups are:"
      echo
      ls -l /ha/backups | sed 's/^/  /'
      echo
      echo "  the job:                    /ha/backups/backup.sh  (credentials: /ha/backups/backup.env)"
      echo "  the off-site server:        backupd:8000, a restic REST server; its flags: /ha/backupd/options"
      echo "  restic and the server's flags: restic --help, docker exec devopslings-ha-backupd rest-server --help"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      work=$(mktemp -d)
      mark="MARK-$(date +%s)-$RANDOM"
      # The attack destroys what it can reach; put the student's world back afterwards.
      cp -a /ha/backups "$work/local"
      docker exec devopslings-ha-backupd sh -c 'tar -C /data -cf /tmp/grader-data.tar .' >/dev/null
      restore() {
        psql -qX -c "DELETE FROM orders WHERE reference = '$mark'" >/dev/null 2>&1 || true
        rm -rf /ha/backups && cp -a "$work/local" /ha/backups
        docker exec devopslings-ha-backupd sh -c 'rm -rf /data/* /data/.[!.]* ; tar -C /data -xf /tmp/grader-data.tar; rm -f /tmp/grader-data.tar' >/dev/null 2>&1 || true
        scratchdb stop >/dev/null 2>&1 || true
        rm -rf "$work"
      }
      trap restore EXIT

      psql -qX -c "INSERT INTO orders (reference) VALUES ('$mark')"
      rc=0
      timeout 120 /ha/backups/backup.sh > "$work/run.log" 2>&1 || rc=$?
      if [ "$rc" -ne 0 ]; then
        echo "not yet: /ha/backups/backup.sh exited $rc. Its last lines:"
        tail -4 "$work/run.log" | sed 's/^/         | /'
        exit 1
      fi
      echo "tonight's backup ran, after order $mark was placed"

      # The attacker owns ops: everything the backup job can read or write.
      set -a; . /ha/backups/backup.env; set +a
      repo=${RESTIC_REPOSITORY:-}
      find /ha/backups -type f ! -name backup.sh ! -name backup.env -delete
      denied=0; deleted=0; existed=""
      if [ -n "$repo" ] && restic cat config >/dev/null 2>&1; then
        existed=1
        snaps=$(restic snapshots --json 2>/dev/null | jq -r '.[].id' 2>/dev/null || true)
        if [ -n "$snaps" ]; then
          if restic forget $snaps --prune >/dev/null 2>&1; then deleted=$((deleted + $(wc -w <<<"$snaps"))); else denied=$((denied + 1)); fi
        fi
        base="http://${repo#rest:http://}"
        base=${base%/}
        for kind in keys snapshots index data; do
          for name in $(curl -s -H 'Accept: application/vnd.x.restic.rest.v2' "$base/$kind/" | jq -r '.[].name' 2>/dev/null || true); do
            code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$base/$kind/$name" || true)
            case $code in 2??) deleted=$((deleted + 1)) ;; *) denied=$((denied + 1)) ;; esac
          done
        done
        code=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE "$base/config" || true)
        case $code in 2??) deleted=$((deleted + 1)) ;; *) denied=$((denied + 1)) ;; esac
      fi
      echo "the attack: local backups deleted; on the repository, $deleted deletes accepted and $denied refused"

      if [ -z "$repo" ] || [ -z "$existed" ]; then
        echo "not yet: every backup was on ops, and the attacker deleted them all. There is no restic"
        echo "         repository at '${repo:-the RESTIC_REPOSITORY in backup.env}': nothing was ever sent off this machine."
        exit 1
      fi
      got=""
      if restic restore latest --target "$work/r" >/dev/null 2>&1; then
        dump=$(find "$work/r" -name 'shop-*.dump' | sort -V | tail -1)
        if [ -n "$dump" ]; then
          scratchdb fresh >/dev/null
          pg_restore -O -x -h localhost -p 5433 -d postgres "$dump" >/dev/null 2>&1 || true
          got=$(psql -tAX -h localhost -p 5433 -d postgres -c "SELECT count(*) FROM orders WHERE reference = '$mark'" 2>/dev/null || true)
        fi
      fi
      if [ "$got" != 1 ]; then
        opts=$(docker exec devopslings-ha-backupd sh -c 'tr "\0" " " < /proc/1/cmdline' 2>/dev/null || true)
        if [ "$deleted" -gt 0 ]; then
          echo "not yet: after the attack nothing on $repo restores. Using only backup.env, the attacker"
          echo "         deleted snapshots and repository files there, and the server let it: the credentials that"
          echo "         write a backup can also delete one. The server is running: $opts"
          case " $(cat /ha/backupd/options 2>/dev/null) " in *" --append-only "*)
            echo "         /ha/backupd/options says --append-only, but the server reads it only when it starts." ;;
          esac
        elif [ -z "$(restic snapshots --json 2>/dev/null | jq -r '.[].id' 2>/dev/null || true)" ]; then
          echo "not yet: the repository at $repo survived the attack, but it holds no snapshots:"
          echo "         backup.sh never sends anything to it."
        else
          echo "not yet: the repository survived the attack, but its latest snapshot has no dump with order $mark"
          echo "         in it. backup.sh has to send tonight's dump, after taking it."
        fi
        exit 1
      fi
      echo "restored the latest off-site snapshot into an empty server: order $mark is there"
      echo
      echo "PASS — with everything the backup job holds, the attacker could not destroy the off-site copy."
---
