---
kind: lesson
title: "four services, buy or build"
description: |
  Four services, and for each one the question of whether to run it
  yourself or pay a provider to. Pick, name what the managed option takes
  off the on-call rotation, and name what it costs you. An answer with no
  downside is not an answer.
name: managed-versus-self
slug: managed-versus-self
createdAt: "2026-11-15"

sandbox:
  stack: iac-stack
  service: ws

tasks:
  init_scenario:
    init: true
    timeout_seconds: 60
    run: |
      rm -rf /root/verdicts
      install -d /root/verdicts/services
      cd /root/verdicts

      cat > services/1-orders-db.md <<'CASE'
      # 1 — the orders database

      Postgres, 200 GB, standard extensions only. The checkout team is three
      developers and no DBA. It runs on two VMs with streaming replication.

      The last outage: the primary's disk failed at 03:10. Promoting the
      replica and repointing the application took 40 minutes, because the
      runbook was out of date and the person on call had never done it.
      Backups have been tested and work.

      The managed offering costs about 1.6 times the two VMs, and moving
      off it later means a dump and restore with downtime.
      CASE

      cat > services/2-search.md <<'CASE'
      # 2 — product search

      A six-node search cluster, stable for two years. The team that runs it
      spends about a day a month on version upgrades and OS patching, and has
      not been paged by it this year.

      The managed offering supports every feature and plugin they use. Its
      quote, for the same capacity, is four times what the six nodes cost,
      and the difference is larger than the salary time the upgrades take.
      CASE

      cat > services/3-backups.md <<'CASE'
      # 3 — backup storage

      Every backup in the company goes to a self-hosted object store on
      three servers. Twice this year it ran out of disk at night and backups
      failed until someone added a drive. One drive failure took a weekend of
      rebalancing. It has grown 40% a year, and the next servers have to be
      ordered three months ahead.

      Managed object storage would charge per GB stored, and per GB read
      back out, which matters for a full restore.
      CASE

      cat > services/4-analytics-db.md <<'CASE'
      # 4 — the analytics database

      Postgres with a C extension the data team wrote for their geospatial
      models, which needs superuser to install and to upgrade. It is the
      reason the models run in minutes instead of hours.

      The managed Postgres offerings available to the company do not grant
      superuser and allow only a fixed list of extensions; this one is not
      on any of them. The team's toil today is mostly the nightly backup
      job and the restore drill every quarter.
      CASE

      cat > verdicts.txt <<'ANS'
      # One line per service. Replace every ? with your answer.
      #
      #   choice=   managed | self
      #   removes=  what the managed option would take off the on-call rotation:
      #             failover | patching | capacity | backups
      #   adds=     what the managed option would cost you, the downside:
      #             cost | lock-in | limits | latency | none
      #
      # Fill in removes= and adds= whichever way you choose. For "managed", adds=
      # is the price you accept; for "self", it is the reason you say no.

      service-1: choice=? removes=? adds=?
      service-2: choice=? removes=? adds=?
      service-3: choice=? removes=? adds=?
      service-4: choice=? removes=? adds=?
      ANS

      cat > README <<'TXT'
      Four services, in services/. For each, decide whether to run it
      yourself or buy the managed offering, and write it in verdicts.txt.

      Every managed option takes something off the on-call rotation and adds
      something: a bill, a dependency, a limit. A verdict that names no
      downside is rejected.

      Nothing needs to be installed or run. You are graded on the verdicts.
      TXT
      echo "scenario ready — four services in /root/verdicts/services, verdicts in /root/verdicts/verdicts.txt"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 60
    run: |
      ans=/root/verdicts/verdicts.txt
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty — reset the lesson to get the template back"
        exit 1
      fi
      fail=0
      # service choice removes adds-accepted (|-separated)
      for row in "1 managed failover cost|lock-in" "2 self patching cost" "3 managed capacity cost|lock-in" "4 self backups limits"; do
        set -- $row
        n=$1 want_choice=$2 want_rm=$3 want_add=$4
        line=$(grep -E "^service-$n:" "$ans" | head -1 || true)
        if [ -z "$line" ]; then
          echo "not yet: no 'service-$n:' line in $ans"
          exit 1
        fi
        field() { printf '%s' "$line" | sed -n "s/.*$1=\([A-Za-z?-]*\).*/\1/p" | tr 'A-Z' 'a-z'; }
        choice=$(field choice) rm=$(field removes) add=$(field adds)
        case "$choice" in managed|self) ;; *) echo "not yet: service-$n needs choice= managed or self"; exit 1 ;; esac
        case "$rm" in failover|patching|capacity|backups) ;; *) echo "not yet: service-$n needs removes= one of: failover patching capacity backups"; exit 1 ;; esac
        case "$add" in cost|lock-in|limits|latency|none) ;; *) echo "not yet: service-$n needs adds= one of: cost lock-in limits latency none"; exit 1 ;; esac

        if [ "$add" = none ]; then
          fail=1
          echo "not yet: service-$n says the managed option adds nothing. Every one does: a bill, a"
          echo "         dependency on one provider, or a limit on what you can run. Name the one"
          echo "         this case turns on"
          continue
        fi
        if [ "$choice" != "$want_choice" ]; then
          fail=1
          echo "not yet: service-$n — you chose $choice."
          case "$n" in
            1) echo "         What went wrong last time, and is that something a provider does for you?" ;;
            2) echo "         Weigh what the toil costs against what the quote costs. Has it been paging anyone?" ;;
            3) echo "         Count the nights this year it needed someone, and what the next year of growth needs." ;;
            4) echo "         Before weighing the toil: can the managed offering run this database at all?" ;;
          esac
          continue
        fi
        if [ "$rm" != "$want_rm" ]; then
          fail=1
          echo "not yet: service-$n — $choice is right, and '$rm' is not the toil the case describes."
          echo "         Which part of running it does the case say costs the team nights or days?"
        fi
        case "|$want_add|" in
          *"|$add|"*) ;;
          *) fail=1
             echo "not yet: service-$n — $choice is right, and '$add' is not the downside that decides it."
             case "$n" in
               2) echo "         Every feature is supported, so nothing limits them. What does the quote say?" ;;
               4) echo "         The bill is not the issue. Read what the managed offerings do not allow" ;;
               *) echo "         Reread the case's last paragraph: it says what the provider charges, in"
                  echo "         money or in what leaving would take" ;;
             esac ;;
        esac
      done
      if [ "$fail" = 1 ]; then
        exit 1
      fi
      echo "PASS — each service has a verdict, what the managed option removes, and what it costs."
---
