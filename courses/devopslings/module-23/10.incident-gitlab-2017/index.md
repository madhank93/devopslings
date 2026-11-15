---
kind: lesson
title: "Replay: GitLab, January 2017"
description: |
  Five backup and replication methods, each one quietly broken, and nobody
  knew until the day all five were needed. Write the verification job that
  would have said so, for every one of them, before anything was deleted.
name: incident-gitlab-2017
slug: incident-gitlab-2017
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
      # The grader's levers: break_<method> and heal_<method>, each idempotent.
      mkdir -p /var/lib/devopslings
      cat > /var/lib/devopslings/gitlab-methods.sh <<'SH'
      B=/ha/backups
      stamp() { date +%Y%m%dT%H%M%S%N; }
      archived() {  # archived ok|failed: wait until the archiver's last attempt went that way
        local want=$1 seg q i
        q="SELECT CASE WHEN last_failed_time IS NOT NULL AND (last_archived_time IS NULL OR last_failed_time > last_archived_time) THEN 'failed' ELSE 'ok' END FROM pg_stat_archiver"
        # txid_current() writes a commit record, so the switch always closes a segment.
        seg=$(psql -qtAX -c "SELECT txid_current()" -c "SELECT pg_walfile_name(pg_switch_wal())" | tail -1)
        for i in $(seq 100); do
          if [ "$want" = ok ]; then
            [ "$(psql -tAX -c "$q")" = ok ] && [ "$(psql -tAX -c "SELECT last_archived_wal >= '$seg' FROM pg_stat_archiver")" = t ] && return 0
          else
            [ "$(psql -tAX -c "$q")" = failed ] && return 0
          fi
          sleep 0.3
        done
        return 1
      }
      heal_dumps() { pg_dump shop | gzip > "$B/dumps/shop-$(stamp).sql.gz"; }
      break_dumps() { gzip < /dev/null > "$B/dumps/shop-$(stamp).sql.gz"; }
      heal_snapshots() {
        if [ -d "$B/.held-snapshot" ]; then mv "$B/.held-snapshot" "$B/snapshots/snap-$(date +%Y%m%dT%H%M%S)"
        else mkdir -p "$B/snapshots/snap-$(date +%Y%m%dT%H%M%S)"; echo "lvm snapshot of pg1's volume" > "$B/snapshots/snap-$(date +%Y%m%dT%H%M%S)/manifest"; fi
      }
      break_snapshots() {
        local d
        for d in $(find "$B/snapshots" -mindepth 1 -maxdepth 1 -type d -newermt '-2 days'); do
          rm -rf "$B/.held-snapshot"; mv "$d" "$B/.held-snapshot"
        done
      }
      heal_wal-archive() {
        psql -qX -c "ALTER SYSTEM SET archive_command = 'test ! -f $B/wal/%f && cp %p $B/wal/%f'" -c "SELECT pg_reload_conf()" >/dev/null
        archived ok
      }
      break_wal-archive() {
        psql -qX -c "ALTER SYSTEM SET archive_command = 'cp %p $B/wal-2016/%f'" -c "SELECT pg_reload_conf()" >/dev/null
        archived failed
      }
      heal_replica() {
        psql -qtAX -h pg2 -c "SELECT pg_wal_replay_resume() WHERE pg_is_wal_replay_paused()" >/dev/null
        for _ in $(seq 120); do
          [ "$(psql -tAX -c "SELECT count(*) FROM pg_stat_replication WHERE application_name = 'pg2' AND replay_lsn = pg_current_wal_lsn()")" = 1 ] && return 0
          sleep 0.5
        done
        return 1
      }
      break_replica() {
        psql -qtAX -h pg2 -c "SELECT pg_wal_replay_pause()" >/dev/null
        psql -qX -c "INSERT INTO activity (note) SELECT md5(g::text) FROM generate_series(1, 50000) g" -c "DELETE FROM activity" >/dev/null
      }
      offsite() { ( set -a; . "$B/offsite.env"; set +a; restic "$@" ); }
      heal_offsite() {
        [ -n "$(offsite snapshots --json 2>/dev/null | jq -r '.[] | select(.time > (now - 3600 | todate)) | .id' 2>/dev/null)" ] \
          || offsite backup --quiet "$B/dumps" >/dev/null
      }
      break_offsite() {
        local ids; ids=$(offsite snapshots --json | jq -r '.[].id')
        if [ -n "$ids" ]; then offsite forget $ids --prune >/dev/null 2>&1; fi
      }
      SH

      . /var/lib/devopslings/gitlab-methods.sh
      docker exec devopslings-ha-backupd sh -c 'rm -rf /data/offsite' || true
      docker restart devopslings-ha-backupd >/dev/null
      for _ in $(seq 60); do curl -s -o /dev/null --max-time 1 http://backupd:8000/ && break; sleep 0.5; done
      mkdir -p "$B/dumps" "$B/snapshots" "$B/wal"
      chown postgres:postgres "$B/wal"
      psql -qX -v ON_ERROR_STOP=1 -c "DROP TABLE IF EXISTS activity" -c "CREATE TABLE activity (id bigserial PRIMARY KEY, note text)" \
        -c "ALTER SYSTEM SET archive_mode = on" -c "ALTER SYSTEM SET archive_timeout = 60"
      docker restart devopslings-ha-pg1 >/dev/null
      for _ in $(seq 120); do pg_isready -q -h pg1 && break; sleep 0.5; done
      for _ in $(seq 60); do
        [ "$(psql -tAX -c "SELECT count(*) FROM pg_stat_replication WHERE application_name = 'pg2' AND state = 'streaming'")" = 1 ] && break
        sleep 0.5
      done
      pw=$(head -c 24 /dev/urandom | base64 | tr -d '/+=')
      printf 'RESTIC_REPOSITORY=rest:http://backupd:8000/offsite\nRESTIC_PASSWORD=%s\n' "$pw" > "$B/offsite.env"
      offsite init >/dev/null

      # Older, good copies from before things went wrong.
      for d in 9 8 7 6; do
        f="$B/dumps/shop-$(date -d "-$d days" +%Y%m%dT020000000000000).sql.gz"
        pg_dump shop | gzip > "$f"; touch -d "-$d days" "$f"
        s="$B/snapshots/snap-$(date -d "-$d days" +%Y%m%dT0400)"
        mkdir -p "$s"; echo "lvm snapshot of pg1's volume" > "$s/manifest"; touch -d "-$d days" "$s/manifest" "$s"
      done
      # Then each method failing in its own quiet way.
      break_dumps
      heal_wal-archive && break_wal-archive
      break_replica
      mkdir -p /ha/dr
      cat > /ha/dr/backups.txt <<'TXT'
      How the shop's database is protected. Five methods; any one of them should be
      enough to get the data back.

      dumps        A pg_dump of shop every night, gzipped: /ha/backups/dumps/shop-<time>.sql.gz
      snapshots    A snapshot of pg1's volume every 24 hours: /ha/backups/snapshots/snap-<time>/
      wal-archive  pg1 archives every WAL segment to /ha/backups/wal/ (archive_timeout 60s).
                   Its archiver's own counters are in pg_stat_archiver.
      replica      pg2, a streaming hot standby of pg1. It should be seconds behind, never more.
      offsite      A restic repository on backupd, written every night. Credentials:
                   /ha/backups/offsite.env
      TXT
      cat > /ha/dr/verify-backups.sh <<'SH'
      #!/bin/bash
      # Checks every backup method. For each one that is not working, prints a line
      #   FAIL <method>: <why>
      # with <method> one of: dumps snapshots wal-archive replica offsite.
      # Exits 0 only when all five are working.
      exit 0
      SH
      chmod +x /ha/dr/verify-backups.sh
      echo "scenario ready — five ways the shop's data is copied, and a job that checks none of them."
      echo
      echo "  the five methods:    /ha/dr/backups.txt"
      echo "  your verification:   /ha/dr/verify-backups.sh"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      lib=/var/lib/devopslings/gitlab-methods.sh
      if [ ! -f "$lib" ]; then
        echo "not yet: the scenario's fault controls are missing. Reset the lesson."
        exit 1
      fi
      . "$lib"
      methods="dumps snapshots wal-archive replica offsite"
      job=/ha/dr/verify-backups.sh
      if [ ! -x "$job" ]; then
        echo "not yet: $job is missing or not executable."
        exit 1
      fi
      out=$(mktemp)
      run_job() {  # run_job: sets rc and fails (the methods it printed FAIL for)
        rc=0
        timeout 120 "$job" > "$out" 2>&1 || rc=$?
        fails=$(grep -Eo '^FAIL[[:space:]]+[a-z-]+' "$out" | awk '{print $2}' | sort -u | tr '\n' ' ' || true)
        fails=${fails% }
      }
      show() { tail -6 "$out" | sed 's/^/         | /'; }
      heal_all() { for m in $methods; do "heal_$m" || { echo "not yet: the grader could not repair $m; reset the lesson."; exit 1; }; done; }

      heal_all
      run_job
      if [ "$rc" -ne 0 ] || [ -n "$fails" ]; then
        echo "not yet: with all five methods working, the job exited $rc and reported: ${fails:-nothing}. Its output:"
        show
        echo "         A check that alarms on a healthy system gets silenced, and then it catches nothing."
        if [ "$fails" = wal-archive ]; then
          echo "         pg_stat_archiver's counters are totals since its last reset: failures from before the repair stay counted."
        fi
        exit 1
      fi
      echo "all five working: the job exited 0 and reported nothing"

      for m in $methods; do
        "break_$m" || { echo "not yet: the grader could not break $m; reset the lesson."; exit 1; }
        run_job
        "heal_$m" || true
        if [ "$rc" -eq 0 ] || [ "$fails" != "$m" ]; then
          echo "not yet: with only $m broken, the job exited $rc and reported FAIL for: ${fails:-nothing}."
          if [[ " $fails " == *" $m "* ]] && [ "$rc" -eq 0 ]; then
            echo "         It named $m but exited 0. Whatever runs the job only sees the exit status: exit non-zero when anything failed."
          elif [[ " $fails " == *" $m "* ]]; then
            echo "         It also named methods that are working. An alarm that names the wrong method sends people the wrong way."
          elif [ -z "$fails" ] && [ "$rc" -ne 0 ]; then
            echo "         It exited $rc without printing a 'FAIL $m: <why>' line, so nobody is told what broke."
          else
            case $m in
              dumps) echo "         The newest dump is a valid gzip file of an empty stream: the job ran, and pg_dump wrote nothing." ;;
              snapshots) echo "         The newest snapshot is days old: snapshots are meant to happen every 24 hours." ;;
              wal-archive) echo "         pg1's archiver is failing every segment; pg_stat_archiver counts the failures." ;;
              replica) echo "         pg2 is streaming but has stopped replaying: it falls further behind pg1 with every write." ;;
              offsite) echo "         The offsite repository exists and is empty: no snapshots." ;;
            esac
          fi
          echo "         The job's output:"
          show
          exit 1
        fi
        echo "only $m broken: the job failed and named it"
      done
      rm -f "$out"
      echo
      echo "PASS — the job stays quiet on a healthy system and names each of the five failures on its own."
---
