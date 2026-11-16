---
kind: lesson
title: "RPO and RTO first"
description: |
  A colleague has proposed a backup design and asked you to sign it off. It
  starts with the tool and never mentions what it has to achieve. Write the
  objectives first, then a design, and make the two agree — the grader
  works out what your design can actually deliver from the measured numbers
  and holds it to what you promised.
name: rpo-and-rto-first
slug: rpo-and-rto-first
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
      mkdir -p /ha/dr
      cat > /ha/dr/proposal.txt <<'TXT'
      Backup proposal for the shop database                       (draft, for sign-off)

      We already run a streaming replica, pg2. It is a full, live copy of pg1 on
      separate hardware, so it is our backup. As belt and braces, add a nightly
      pg_dump at 02:00.
      TXT
      cat > /ha/dr/facts.txt <<'TXT'
      Measured on production, last quarter. The database is 120 GB.

      The business
        Losing more than 15 minutes of orders is not acceptable.
        The shop must take orders again within 60 minutes of the decision to recover.
        Last year's worst incident was a deploy that ran DELETE without a WHERE.

      People
        On-call acknowledges, looks, and decides to restore:        15 minutes

      pg_dump (logical)
        Taking a dump:                                              50 minutes
        Restoring one into an empty server (data, then indexes):   190 minutes

      pg_basebackup + WAL archive (physical)
        Taking a base backup:                                       40 minutes
        Restoring one (copying the files back):                     25 minutes
        Replaying archived WAL, per hour of WAL since that backup:   4 minutes
        A WAL segment is archived when it fills or archive_timeout
        expires; at night the shop writes far less than a segment an hour.

      Streaming replica (pg2)
        Lag behind pg1:                                         under 1 second
        Promoting it:                                                1 minute
      TXT
      cat > /ha/answers/rpo-rto.txt <<'TXT'
      # Objectives first. Whole minutes.
      rpo_minutes: ?
      rto_minutes: ?

      # Then the design that meets them.
      # method: dump, basebackup+wal or replica
      method: ?
      # How often a full backup (a dump or a base backup) is taken, in whole hours.
      full_backup_every_hours: ?
      # basebackup+wal only: archive_timeout in seconds. Otherwise 0.
      archive_timeout_seconds: ?
      TXT
      echo "scenario ready — a backup design is waiting for your sign-off:"
      echo
      echo "  the proposal:       /ha/dr/proposal.txt"
      echo "  what was measured:  /ha/dr/facts.txt"
      echo "  your answer:        /ha/answers/rpo-rto.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 60
    run: |
      a=/ha/answers/rpo-rto.txt
      val() { sed -n "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*//p" "$a" 2>/dev/null | head -1 | tr -d ' \t' | tr '[:upper:]' '[:lower:]' || true; }
      num() {  # num <key> <var>: a whole number, or a not-yet and exit
        local v; v=$(val "$1")
        if ! [[ $v =~ ^[0-9]+$ ]]; then
          echo "not yet: $1 in $a is '${v:-missing}'; it needs a whole number."
          exit 1
        fi
        printf -v "$2" '%s' "$v"
      }
      line() { grep -n "^[[:space:]]*$1[[:space:]]*:" "$a" 2>/dev/null | head -1 | cut -d: -f1 || true; }

      num rpo_minutes rpo
      num rto_minutes rto
      m=$(line method)
      if [ -n "$m" ] && { [ "$m" -lt "$(line rpo_minutes)" ] || [ "$m" -lt "$(line rto_minutes)" ]; }; then
        echo "not yet: the method comes before the objectives in $a. State what the design must achieve, then the design."
        exit 1
      fi
      if [ "$rpo" -gt 15 ] || [ "$rto" -gt 60 ]; then
        echo "not yet: you set RPO $rpo and RTO $rto minutes. /ha/dr/facts.txt says the business accepts at most"
        echo "         15 minutes of lost orders and 60 minutes to recover. Objectives looser than that are not objectives."
        exit 1
      fi
      method=$(val method)
      case $method in dump|basebackup+wal|replica) ;; *)
        echo "not yet: method is '${method:-missing}'; it must be dump, basebackup+wal or replica."
        exit 1 ;;
      esac
      num full_backup_every_hours every
      num archive_timeout_seconds timeout

      if [ "$method" = replica ]; then
        echo "not yet: a replica is not a backup. It replays every change within a second, including last year's"
        echo "         DELETE without a WHERE: when you notice, pg2 has deleted the same rows. Its RPO for that"
        echo "         incident is everything, whatever its lag says."
        exit 1
      fi
      if [ "$every" -lt 1 ]; then
        echo "not yet: full_backup_every_hours is 0. A full backup cannot be taken more often than it takes to run."
        exit 1
      fi

      if [ "$method" = dump ]; then
        loss=$((every * 60))
        restore=$((15 + 190))
        echo "a dump every $every h: up to $loss minutes of orders lost; recovery 15 + 190 = $restore minutes"
        if [ "$loss" -gt "$rpo" ]; then
          echo "not yet: everything since the last dump is lost, so a dump every $every hours loses up to $loss minutes."
          echo "         Your RPO is $rpo. A dump takes 50 minutes, so dumps cannot run every $rpo minutes either."
          exit 1
        fi
        echo "not yet: restoring a dump takes 190 minutes, plus 15 to decide: $restore minutes, against an RTO of $rto."
        exit 1
      fi

      loss=$(( (timeout + 59) / 60 ))
      if [ "$timeout" -eq 0 ]; then
        echo "not yet: with archive_timeout 0 a WAL segment is archived only when it fills, and at night that can"
        echo "         be more than an hour. Set archive_timeout to bound how old the newest archived change can be."
        exit 1
      fi
      restore=$((15 + 25 + 4 * every))
      echo "base backup every $every h, archive_timeout ${timeout}s: up to $loss minutes lost; recovery 15 + 25 + 4 x $every = $restore minutes"
      if [ "$loss" -gt "$rpo" ]; then
        echo "not yet: anything not yet archived is lost with pg1. archive_timeout $timeout s means up to $loss minutes,"
        echo "         and your RPO is $rpo."
        exit 1
      fi
      if [ "$restore" -gt "$rto" ]; then
        echo "not yet: a restore replays all the WAL since the last base backup: 4 minutes per hour, so up to $((4 * every))"
        echo "         minutes with a base backup every $every hours. 15 to decide + 25 to copy + $((4 * every)) to replay is $restore,"
        echo "         and your RTO is $rto. Take base backups more often."
        exit 1
      fi
      echo "PASS — objectives RPO $rpo / RTO $rto, and a design that delivers $loss / $restore."
---
