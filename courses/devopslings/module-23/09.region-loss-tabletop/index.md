---
kind: lesson
title: "Tabletop: the region is gone"
description: |
  At 09:12 the shop's cloud region, eu-1, goes dark, and the provider
  estimates six hours. Write the plan that has the shop taking orders
  elsewhere within the hour: every step, what it uses, how long it takes,
  and who makes the call. Anything that lives in eu-1 does not exist today.
name: region-loss-tabletop
slug: region-loss-tabletop
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
      cat > /ha/dr/inventory.txt <<'TXT'
      # Everything the shop runs on. minutes: how long a recovery step that uses it
      # takes at least, from the moment the step starts.
      #
      # name                 region   minutes  what it is
      pg-primary             eu-1     -        the Postgres primary
      pg-replica             eu-1     5        streaming replica of pg-primary, promotable
      basebackup-eu1         eu-1     20       nightly base backups
      basebackup-us2         us-2     20       copy of basebackup-eu1, synced every 4 hours
      wal-archive-eu1        eu-1     15       WAL archive, archive_timeout 300s
      wal-archive-us2        us-2     15       cross-region copy of wal-archive-eu1, under 2 minutes behind
      dump-us2               us-2     190      nightly pg_dump, copied over at 03:00
      vm-pool-eu1            eu-1     5        the app servers
      vm-pool-us2            us-2     5        spare app servers, cold
      registry-eu1           eu-1     5        container registry the deploys pull from
      registry-mirror-us2    us-2     5        pull-through mirror of registry-eu1, synced hourly
      bao-eu1                eu-1     5        OpenBao, the shop's secrets
      bao-escrow-us2         us-2     10       sealed export of OpenBao's secrets; two officers hold the keys
      dns-eu1                eu-1     5        the shop's authoritative DNS, self-hosted
      dns-provider           global   5        managed DNS, secondary for the shop's zone; can be made primary
      runbooks-wiki          eu-1     0        the wiki the runbooks are written in
      runbooks-git           global   0        the runbooks, mirrored to the git host every night
      pager                  global   0        the paging service
      TXT
      cat > /ha/dr/roster.txt <<'TXT'
      # Who is who on the day. Only the incident commander and the VP engineering
      # may decide to fail the shop over to another region.
      #
      # name      role
      priya       incident commander (this week's rotation)
      marco       VP engineering
      sam         on-call SRE, paged first
      dana        DBA
      TXT
      grep -Ev '^[[:space:]]*(#|$)' /ha/dr/inventory.txt | awk '{print $1, $2, $3}' \
        | docker exec -i devopslings-ha-pg1 sh -c 'cat > /var/lib/postgresql/region-inventory'
      cat > /ha/answers/region-loss.txt <<'TXT'
      # The objectives this plan meets. Whole minutes.
      rpo_minutes: ?
      rto_minutes: ?
      # Who decides to fail over: a name from /ha/dr/roster.txt.
      decision_owner: ?

      # The steps after the decision, in order. One per line:
      #   step: <minutes> | <inventory names it uses, comma-separated> | <what happens>
      # e.g.
      #   step: 5 | pager, runbooks-git | page the DBA and open the runbook
      TXT
      echo "scenario ready — 09:12, eu-1 is down, and the provider says six hours."
      echo
      echo "  what the shop runs on:  /ha/dr/inventory.txt"
      echo "  who is who:             /ha/dr/roster.txt"
      echo "  your plan:              /ha/answers/region-loss.txt"
      echo "  the objectives:         RPO 15 minutes, RTO 60 minutes (the module's)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 60
    run: |
      a=/ha/answers/region-loss.txt
      inv=$(docker exec devopslings-ha-pg1 cat /var/lib/postgresql/region-inventory 2>/dev/null || true)
      if [ -z "$inv" ]; then
        echo "not yet: the scenario's inventory record is missing. Reset the lesson."
        exit 1
      fi
      val() { sed -n "s/^[[:space:]]*$1[[:space:]]*:[[:space:]]*//p" "$a" 2>/dev/null | head -1 | tr -d ' \t' | tr '[:upper:]' '[:lower:]' || true; }
      region() { awk -v n="$1" '$1 == n { print $2 }' <<<"$inv"; }
      cost() { awk -v n="$1" '$1 == n { print $3 }' <<<"$inv"; }

      owner=$(val decision_owner)
      case $owner in
        priya|marco) ;;
        sam|dana)
          echo "not yet: decision_owner is $owner. The roster says only the incident commander or the VP engineering"
          echo "         may fail the shop over. Someone else can page them and prepare, but a plan that leaves the"
          echo "         call to whoever is awake gets two people deciding differently at 09:30."
          exit 1 ;;
        *)
          echo "not yet: decision_owner is '${owner:-missing}'; name one person from /ha/dr/roster.txt."
          exit 1 ;;
      esac
      for k in rpo_minutes rto_minutes; do
        if ! [[ $(val $k) =~ ^[0-9]+$ ]]; then
          echo "not yet: $k in $a is '$(val $k)'; it needs a whole number."
          exit 1
        fi
      done
      rpo=$(val rpo_minutes); rto=$(val rto_minutes)
      if [ "$rpo" -gt 15 ] || [ "$rto" -gt 60 ]; then
        echo "not yet: the plan states RPO $rpo / RTO $rto. The shop's objectives are RPO 15 and RTO 60 minutes."
        exit 1
      fi

      steps=$(sed -n 's/^[[:space:]]*step[[:space:]]*:[[:space:]]*//p' "$a" 2>/dev/null || true)
      if [ -z "$steps" ]; then
        echo "not yet: the plan has no 'step:' lines."
        exit 1
      fi
      total=0; used=" "; n=0
      while IFS='|' read -r mins res what; do
        n=$((n + 1))
        mins=$(tr -d ' \t' <<<"$mins")
        if ! [[ $mins =~ ^[0-9]+$ ]]; then
          echo "not yet: step $n starts with '$mins'; it needs a whole number of minutes."
          exit 1
        fi
        need=0
        for r in $(tr ',' ' ' <<<"$res"); do
          reg=$(region "$r")
          if [ -z "$reg" ]; then
            echo "not yet: step $n uses '$r', which is not in /ha/dr/inventory.txt."
            exit 1
          fi
          if [ "$reg" = eu-1 ]; then
            echo "not yet: step $n ($(sed 's/^[[:space:]]*//; s/[[:space:]]*$//' <<<"$what")) uses $r, which is in eu-1. eu-1 is down: $r does not exist today."
            case $r in
              pg-replica) echo "         The replica is a copy in the same region. It protects against losing a server, not a region." ;;
              runbooks-wiki) echo "         The runbook is in the region it tells you how to leave. runbooks-git has a copy." ;;
            esac
            exit 1
          fi
          c=$(cost "$r"); need=$((need + ${c//-/0}))
          used="$used$r "
        done
        if [ "$mins" -lt "$need" ]; then
          echo "not yet: step $n allows $mins minutes, but what it uses takes at least $need (see the minutes column)."
          exit 1
        fi
        total=$((total + mins))
      done <<<"$steps"

      has() { case "$used" in *" $1 "*) return 0 ;; esac; return 1; }
      if has basebackup-us2 && has wal-archive-us2; then got_rpo=7
      elif has wal-archive-us2; then
        echo "not yet: the plan replays wal-archive-us2, but onto nothing. WAL is a list of changes; it is"
        echo "         replayed on top of a base backup, and basebackup-us2 is not in any step."
        exit 1
      elif has basebackup-us2; then got_rpo=240
      elif has dump-us2; then got_rpo=1440
      else
        echo "not yet: no step brings back the database. Which inventory items hold the shop's data outside eu-1?"
        exit 1
      fi
      if [ "$got_rpo" = 7 ] && [ "$rpo" -lt 7 ]; then
        echo "not yet: the plan states an RPO of $rpo, but the newest data outside eu-1 can be 7 minutes old:"
        echo "         eu-1 archived WAL every 300 seconds, and the us-2 copy runs up to 2 minutes behind that."
        exit 1
      fi
      if [ "$got_rpo" -gt "$rpo" ]; then
        echo "not yet: the plan's data comes from $(has basebackup-us2 && echo basebackup-us2 || echo dump-us2), which can be up to"
        echo "         $got_rpo minutes old. The plan states an RPO of $rpo. What in us-2 is minutes behind, not hours?"
        exit 1
      fi
      for need in "vm-pool-us2:servers to run the app on" "registry-mirror-us2:the images to deploy onto them" \
                  "bao-escrow-us2:the secrets the app needs to start" "dns-provider:a way to send customers to us-2"; do
        if ! has "${need%%:*}"; then
          echo "not yet: nothing in the plan gives the shop ${need#*:}."
          exit 1
        fi
      done
      if [ "$total" -gt "$rto" ]; then
        echo "not yet: the steps add up to $total minutes; the plan states an RTO of $rto."
        exit 1
      fi
      echo "PASS — $n steps, nothing from eu-1: data at most $got_rpo minutes old, taking orders in $total minutes, $owner's call."
---
