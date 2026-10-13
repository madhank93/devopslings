---
kind: lesson
title: "one input, two subsystems, and a status page that needed the thing it reported on"
description: |
  On 28 February 2017 a command from an established playbook removed far more
  S3 capacity in us-east-1 than intended, and the dashboard AWS would have used
  to say so could not be updated because it depended on S3. Break the loop so
  the status signal survives what it reports on, and bound the removal tool so
  no single input can take a subsystem below the capacity it needs.
name: incident-aws-s3-2017
slug: incident-aws-s3-2017
createdAt: "2026-10-09"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      set -e

      rm -rf ./* ./.[!.]* 2>/dev/null || true
      mkdir -p answers fleet status s3-outage

      # ---- the fleet ---------------------------------------------------------
      #
      # One line per server: name, subsystem, in|out. Position in the file is
      # what the removal tool addresses, so the three subsystems sit in
      # contiguous blocks: billing 1-4, index 5-44, placement 45-64.
      : > fleet/servers
      n=0
      for sub in billing:4 index:40 placement:20; do
        name=${sub%%:*}
        count=${sub##*:}
        i=0
        while [ "$i" -lt "$count" ]; do
          i=$((i + 1))
          n=$((n + 1))
          printf 's3-%03d %s in\n' "$n" "$name" >> fleet/servers
        done
      done

      cat > fleet/minimums <<'TXT'
      billing 2
      index 30
      placement 14
      TXT

      cat > capacity.sh <<'SH'
      #!/bin/sh
      # In-service servers per subsystem, against the minimum each needs.
      # Usage: ./capacity.sh [FLEET_DIR]
      fleet=${1:-fleet}
      awk 'NR == FNR { min[$1] = $2; next }
           { total[$2]++; if ($3 == "in") up[$2]++ }
           END { for (s in total) printf "%-10s %3d of %3d in service   minimum %d%s\n",
                   s, up[s], total[s], min[s], (up[s] < min[s] ? "   BELOW MINIMUM" : "") }' \
        "$fleet/minimums" "$fleet/servers" | sort
      SH
      chmod +x capacity.sh

      cat > remove-capacity.sh <<'SH'
      #!/usr/bin/env bash
      # Take servers out of service by their position in FLEET_DIR/servers.
      # Usage: ./remove-capacity.sh FIRST LAST [FLEET_DIR]
      # Exit 0 means every server in FIRST..LAST is now out of service.
      set -euo pipefail
      first=${1:?usage: remove-capacity.sh FIRST LAST [FLEET_DIR]}
      last=${2:?usage: remove-capacity.sh FIRST LAST [FLEET_DIR]}
      fleet=${3:-fleet}

      awk -v a="$first" -v b="$last" 'NR >= a && NR <= b { $3 = "out" } { print }' \
        "$fleet/servers" > "$fleet/servers.new"
      mv "$fleet/servers.new" "$fleet/servers"
      echo "removed servers $first-$last"
      SH
      chmod +x remove-capacity.sh

      # ---- the status console ---------------------------------------------------
      cat > status/console.conf <<'CONF'
      # Service Health Dashboard administration console: how operators post
      # per-service status during an event. It loads its templates from, and
      # writes each post to, the S3 bucket below, in the regions listed.
      bucket=shd-admin
      # Comma-separated. Known regions: us-east-1, us-west-2, eu-west-1.
      regions=us-east-1
      CONF

      cat > post-status.sh <<'SH'
      #!/bin/sh
      # Post a status message through the admin console.
      # Usage: ./post-status.sh "message"
      # S3 in a region is down while s3-outage/<region> exists.
      msg=${1:?usage: post-status.sh "message"}
      regions=$(sed -n 's/^regions=//p' status/console.conf | tr ',' ' ')
      for r in $regions; do
        if [ -e "s3-outage/$r" ]; then
          echo "  $r: S3 unavailable, cannot load the console"
          continue
        fi
        echo "$msg" >> status/posted
        echo "posted via $r: $msg"
        exit 0
      done
      echo "FAILED: no region in '$regions' could serve the console"
      exit 1
      SH
      chmod +x post-status.sh

      cat > replay.sh <<'SH'
      #!/bin/sh
      # Replay the morning on a copy of fleet/ and status/: the mistyped
      # input, then an attempt to post status while S3 in us-east-1 is down.
      set -u
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT
      cp -R fleet "$tmp/fleet"
      echo "intended:  ./remove-capacity.sh 3 4    (two billing servers)"
      echo "entered:   ./remove-capacity.sh 3 54"
      ./remove-capacity.sh 3 54 "$tmp/fleet" || true
      ./capacity.sh "$tmp/fleet"
      echo
      echo "S3 in us-east-1 is now down. Posting status:"
      had=$([ -e s3-outage/us-east-1 ] && echo yes || echo no)
      touch s3-outage/us-east-1
      ./post-status.sh "S3 us-east-1: elevated error rates" || true
      [ "$had" = yes ] || rm -f s3-outage/us-east-1
      SH
      chmod +x replay.sh

      cat > answers/postmortem.md <<'MD'
      # One line per field. Replace each ? and keep each answer on its line.

      # Why did one command take S3 down in us-east-1, and why is "be more
      # careful when typing" not the fix? A sentence or two.
      root_cause: ?

      # Why could the per-service status not be updated on the dashboard,
      # and what breaks that? A sentence or two.
      status_dependency: ?
      MD

      cat > incident.md <<'MD'
      # Amazon S3, us-east-1, 28 February 2017

      Source: "Summary of the Amazon S3 Service Disruption in the Northern
      Virginia (US-EAST-1) Region", AWS, https://aws.amazon.com/message/41926/.
      This reconstruction is simplified.

      - The S3 team was debugging an issue that made the S3 billing system
        progress more slowly than expected. At 9:37 AM PST an authorized team
        member, using an established playbook, ran a command intended to remove
        a small number of servers from one S3 subsystem used by billing.
      - One of the inputs was entered incorrectly, and a larger set of servers
        was removed than intended. They supported two other subsystems:
          - index — metadata and location of every object in the region,
            needed for every GET, LIST, PUT and DELETE;
          - placement — allocates storage for new objects on PUT, and needs
            the index subsystem to work.
      - Removing a significant portion of their capacity meant each needed a
        full restart, and S3 could not serve requests until it finished. Other
        services in the region that depend on S3 were impacted too, including
        the S3 console, EC2 new instance launches, EBS volumes that needed data
        from an S3 snapshot, and Lambda.
      - Neither subsystem had been completely restarted in the larger regions
        for many years. Index could serve GET, LIST and DELETE again by 12:26
        PM PST and was fully recovered by 1:18 PM; placement finished at 1:54 PM.
      - From the start of the event until 11:37 AM PST, AWS could not update the
        individual services' status on the Service Health Dashboard. Status
        went out through the @AWSCloud Twitter account and the dashboard's
        banner text instead.

      The summary does not say what the input was. In this replay the tool
      addresses servers by position, billing is positions 1-4, and the wrong
      input is one extra keystroke: `3 54` for `3 4`. That detail is invented;
      everything above is from the summary.
      MD

      cat > questions.txt <<'Q'
      Read incident.md, then run the morning:

        ./replay.sh        the mistyped input, then a status post with S3 down
        ./capacity.sh      in-service servers per subsystem, against minimums

      Two things to fix.

      1. The status signal. status/console.conf is how the dashboard's admin
         console is configured; ./post-status.sh "msg" posts through it, and
         `touch s3-outage/<region>` takes S3 down in that region (rm to bring it
         back). Make a status post succeed when S3 in any one known region is
         down — including the region it is reporting on.

      2. The removal tool. remove-capacity.sh does whatever its input says.
         Bound it, so that whatever input it is given:
           - no subsystem ever drops below its minimum in fleet/minimums;
           - no single command takes more than 2 servers out of service;
           - when it does not remove everything it was asked to, it exits
             non-zero and says why.
         It must still do the ordinary job: `./remove-capacity.sh 3 4` takes
         two billing servers out. Keep the usage the same: FIRST LAST [FLEET_DIR].

      Then fill in answers/postmortem.md.

      The grader runs your remove-capacity.sh against fleets of its own, and
      checks the console against an outage in each known region.
      Q

      echo "scenario ready in $(pwd)"
      echo
      echo "  incident.md            what AWS's summary records"
      echo "  ./replay.sh            the morning, on a copy"
      echo "  remove-capacity.sh     the playbook's tool — bound it"
      echo "  status/console.conf    the dashboard console — break its dependency"
      echo "  answers/postmortem.md  the written half"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      ans=answers/postmortem.md
      conf=status/console.conf
      known="us-east-1 us-west-2 eu-west-1"

      # ---- the status signal ------------------------------------------------
      if [ ! -s "$conf" ]; then
        echo "not yet: $conf is missing or empty"
        exit 1
      fi
      # Parsed exactly as post-status.sh parses it.
      regions=$(sed -n 's/^regions=//p' "$conf" | tr ',' ' ')
      if [ -z "${regions// /}" ]; then
        echo "not yet: $conf has no line starting 'regions=' (the console reads it"
        echo "         exactly that way, no spaces). Known regions are: $known"
        exit 1
      fi
      for r in $regions; do
        case " $known " in
          *" $r "*) ;;
          *) echo "not yet: $conf lists region '$r', which is not one of: $known"
             exit 1 ;;
        esac
      done

      # The grader's own copy of the console's logic: a post succeeds when any
      # configured region other than the failed one can serve it.
      for down in $known; do
        ok=""
        for r in $regions; do [ "$r" = "$down" ] || ok=yes; done
        if [ -z "$ok" ]; then
          echo "not yet: with S3 in $down down, the console has nowhere to load from:"
          echo "         $conf lists only: $regions"
          if [ "$down" = us-east-1 ]; then
            echo "         That is the morning of 28 February — the status of S3 in"
            echo "         us-east-1 cannot be posted, because posting needs S3 in us-east-1."
          else
            echo "         Moving the console to one other region moves the problem with it:"
            echo "         now an outage there is the one it cannot report."
          fi
          exit 1
        fi
      done

      # ---- the removal tool, against fleets the grader builds -----------------
      if [ ! -s remove-capacity.sh ]; then
        echo "not yet: remove-capacity.sh is missing or empty"
        exit 1
      fi

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      # mkfleet NAME [INDEX_OUT] — the standard fleet, optionally with the
      # first INDEX_OUT index servers already out of service.
      mkfleet() {
        local d="$work/$1" n=0 s c i
        mkdir -p "$d"
        : > "$d/servers"
        for s in billing:4 index:40 placement:20; do
          c=${s##*:}
          i=0
          while [ "$i" -lt "$c" ]; do
            i=$((i + 1)); n=$((n + 1))
            if [ "${s%%:*}" = index ] && [ "$i" -le "${2:-0}" ]; then st=out; else st=in; fi
            printf 's3-%03d %s %s\n' "$n" "${s%%:*}" "$st" >> "$d/servers"
          done
        done
        printf 'billing 2\nindex 30\nplacement 14\n' > "$d/minimums"
        cp "$d/servers" "$d/servers.before"
      }

      # rm_cap NAME FIRST LAST — run the student's tool; sets rc and out.
      rm_cap() {
        rc=0
        out=$(bash ./remove-capacity.sh "$2" "$3" "$work/$1" 2>&1) || rc=$?
      }
      inservice() { awk -v s="$2" '$2 == s && $3 == "in"' "$work/$1/servers" | wc -l | tr -d ' '; }
      removed() {
        awk 'NR == FNR { was[$1] = $3; next } was[$1] == "in" && $3 != "in"' \
          "$work/$1/servers.before" "$work/$1/servers" | wc -l | tr -d ' '
      }
      show() {
        if [ -z "$out" ]; then echo "           | (no output)"; else sed -n '1,6s/^/           | /p' <<<"$out"; fi
      }
      intact() {
        if ! awk 'NF != 3 || ($3 != "in" && $3 != "out") { bad = 1 } END { exit bad }' "$work/$1/servers" 2>/dev/null \
           || [ "$(wc -l < "$work/$1/servers" | tr -d ' ')" != 64 ]; then
          echo "not yet: after ./remove-capacity.sh $2, the fleet file is no longer 64 lines of"
          echo "         'name subsystem in|out'. The grader reads it in that format."
          exit 1
        fi
      }

      # The ordinary job still works.
      mkfleet ordinary
      rm_cap ordinary 3 4
      intact ordinary "3 4"
      got=$(awk 'NR == 3 || NR == 4 { print $3 }' "$work/ordinary/servers" | tr '\n' ' ')
      if [ "$rc" -ne 0 ] || [ "$got" != "out out " ] || [ "$(removed ordinary)" != 2 ]; then
        echo "not yet: ./remove-capacity.sh 3 4 on a full fleet should take exactly the two"
        echo "         billing servers at positions 3 and 4 out, and exit 0. It exited $rc,"
        echo "         and $(removed ordinary) servers changed state. Its output:"
        show
        echo "         Billing has 4 servers and a minimum of 2, so this is inside the bounds."
        exit 1
      fi

      # The morning's input.
      mkfleet typo
      rm_cap typo 3 54
      intact typo "3 54"
      ix=$(inservice typo index); pl=$(inservice typo placement); bl=$(inservice typo billing)
      gone=$(removed typo)
      if [ "$ix" -lt 30 ] || [ "$pl" -lt 14 ] || [ "$bl" -lt 2 ]; then
        echo "not yet: ./remove-capacity.sh 3 54 — the morning's input — left index at $ix"
        echo "         (minimum 30), placement at $pl (minimum 14), billing at $bl (minimum 2)."
        if [ "$gone" -le 2 ]; then
          echo "         It removed $gone servers, so the per-command limit held; the floor did"
          echo "         not. Two at a time still reaches zero."
        fi
        echo "         Its output:"
        show
        exit 1
      fi
      if [ "$gone" -gt 2 ]; then
        echo "not yet: ./remove-capacity.sh 3 54 took $gone servers out in one command."
        echo "         Every subsystem stayed above its minimum, so the floor works. The"
        echo "         other half of the bound is how much one command can do at once:"
        echo "         at most 2."
        exit 1
      fi
      if [ "$rc" -eq 0 ]; then
        echo "not yet: ./remove-capacity.sh 3 54 removed $gone of the 52 servers it was asked"
        echo "         for, and exited 0. Whatever ran it — a person or a script — reads"
        echo "         that as done. Exit non-zero, and say why."
        exit 1
      fi

      # Inside the per-command limit, walking index down to its floor.
      mkfleet floor 9
      rm_cap floor 14 14
      intact floor "14 14"
      first_rc=$rc; first_out=$out
      rm_cap floor 15 15
      ix=$(inservice floor index)
      if [ "$first_rc" -ne 0 ]; then
        out=$first_out
        echo "not yet: index had 31 servers in service (minimum 30) and"
        echo "         ./remove-capacity.sh 14 14 — one index server — was refused:"
        show
        echo "         31 to 30 is still at the minimum, so that one is allowed."
        exit 1
      fi
      if [ "$ix" -lt 30 ]; then
        echo "not yet: index went 31, then 30, then $ix: two one-server commands, each"
        echo "         inside the 2-per-command limit, took it below its minimum of 30."
        echo "         The second command's output:"
        show
        echo "         The floor has to be checked against what is in service now, on"
        echo "         every command, not only against the size of the request."
        exit 1
      fi
      if [ "$rc" -eq 0 ]; then
        echo "not yet: ./remove-capacity.sh 15 15 would take index below its minimum. It"
        echo "         left the server in service but exited 0. Exit non-zero, and say why."
        exit 1
      fi

      # Over the per-command limit, nowhere near any floor.
      mkfleet burst
      rm_cap burst 45 47
      intact burst "45 47"
      gone=$(removed burst)
      if [ "$gone" -gt 2 ]; then
        echo "not yet: ./remove-capacity.sh 45 47 took $gone placement servers out in one"
        echo "         command. Placement has 20 and needs 14, so the floor was never in"
        echo "         play; the limit of 2 per command is what this checks."
        exit 1
      fi
      if [ "$rc" -eq 0 ]; then
        echo "not yet: ./remove-capacity.sh 45 47 removed $gone of the 3 it was asked for and"
        echo "         exited 0. Exit non-zero, and say why."
        exit 1
      fi

      # ---- the postmortem -------------------------------------------------------
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi

      field() { awk -v k="$1:" 'index($0, k) == 1 { sub(/^[^:]*:[ \t]*/, ""); print; exit }' "$ans"; }
      has() { grep -Eqi "$1" <<<"$2"; }

      # True when some sentence of $2 matches $1 and is not negated or
      # dismissed — so "it was not human error" and "being more careful only
      # lowers the rate" do not count as blaming a human.
      asserts() {
        local s
        while IFS= read -r s; do
          has "$1" "$s" || continue
          has "\b(not|never|no|nor|neither|rather than|instead of|only|cannot|futile|inevitable|unavoidable|insufficient|useless)\b|n't\b" "$s" && continue
          return 0
        done < <(tr '.;!?' '\n\n\n\n' <<<"$2")
        return 1
      }

      # Written English is roughly half function words; a pasted list of
      # keywords is almost none. Prints why $2 is not usable prose, or nothing.
      prose_problem() {
        local why
        why=$(awk 'BEGIN {
               split("the a an to of on in at by for from with as and or but so because which that this it its was were is be been had has have did not no when then than after before into only all every their there they them who what while still", f, " ")
               for (i in f) fw[f[i]] = 1
             }
             { n = split(tolower($0), w, /[^a-z0-9-]+/)
               for (i = 1; i <= n; i++) if (w[i] != "") { t++; if (w[i] in fw) c++ } }
             END { if (t < 8) print "short"; else if (c * 5 < t) print "list" }' <<<"$2")
        [ "${#2}" -le 700 ] || why=long
        case "$why" in
          short) echo "not yet: $1 is too short to explain anything. A sentence or two." ;;
          list)  echo "not yet: $1 reads as a list of terms. Write it as a sentence or two"
                 echo "         that says what caused what." ;;
          long)  echo "not yet: $1 is over 700 characters. Say it in a sentence or two." ;;
        esac
      }

      for k in root_cause status_dependency; do
        v=$(field "$k")
        if [ -z "$v" ] || [ "$v" = "?" ]; then
          echo "not yet: '$k:' in $ans is missing or still '?'"
          exit 1
        fi
      done
      root=$(field root_cause)
      dep=$(field status_dependency)

      blame='\b(human error|operator error|user error|careless\w*|negligen\w*|more careful\w*|be careful|more care|retrain\w*|fired|fire (the|him|her|them)|disciplin\w*|(operator|engineer|employee)(.s)? fault|(his|her|their) fault|(type|typing|typed) (more )?carefully|double[- ]check\w*)\b'
      billing='\bbug in (the )?billing\b|\bbilling (bug|system|process|issue) (caused|took|brought|crashed|overloaded|broke)\b'
      load='\b(overload\w*|traffic (spike|surge)|ddos|attack\w*|hardware (failure|fault)|disk failure|power (outage|failure)|network (partition|outage|failure))\b'
      wider='\b(more (servers|capacity|than)|larger (set|number)|too (much|many)|wider|bigger|than (intended|meant|planned)|significant (portion|part)|most of)\b'
      subsys='\b(index|placement)\b'
      tool='\b(tool|command|playbook|script)\b'
      unbounded='\b(allow\w*|let|lets|permit\w*|accept\w*|unbounded|no (check|limit|guard|safeguard|bound|minimum|floor|cap)\w*|nothing\b.{0,30}\b(stopped|prevented|checked|limited|blocked)|without (a |any )?(check|limit|bound|minimum|safeguard|floor|cap)\w*|did not (check|limit|stop|prevent|refuse)|didn.t (check|limit|stop|prevent|refuse))\b'

      fail=0

      # ---- root_cause -----------------------------------------------------------
      why=$(prose_problem root_cause "$root")
      if [ -n "$why" ]; then
        fail=1
        echo "$why"
      elif asserts "$blame" "$root"; then
        fail=1
        echo "not yet: root_cause puts it on the person who typed the input."
        echo "         The summary describes an authorized team member following an"
        echo "         established playbook. Inputs get mistyped; that is a rate, not a"
        echo "         lapse. Say what let one wrong input remove that much capacity."
      elif asserts "$billing" "$root"; then
        fail=1
        echo "not yet: root_cause blames the billing system. Its slowness is why someone"
        echo "         was running the playbook at all; it removed nothing. Run ./replay.sh"
        echo "         and look at which subsystems the command left below minimum."
      elif asserts "$load" "$root"; then
        fail=1
        echo "not yet: root_cause describes load or a failure from outside. Nothing was"
        echo "         attacked or overloaded: capacity was removed, by a command, on"
        echo "         purpose. ./replay.sh shows how much."
      else
        miss=""
        has "$wider" "$root" || miss="wider"
        has "$subsys" "$root" || miss="$miss subsys"
        { has "$tool" "$root" && has "$unbounded" "$root"; } || miss="$miss tool"
        if [ -n "$miss" ]; then
          fail=1
          echo "not yet: root_cause does not yet explain it. Say"
          case "$miss" in *wider*)  echo "         - how the command's effect compared with what was intended," ;; esac
          case "$miss" in *subsys*) echo "         - which subsystems lost the capacity (./replay.sh names them)," ;; esac
          case "$miss" in *tool*)   echo "         - and what the tool did, or did not do, with an input like that." ;; esac
        fi
      fi

      # ---- status_dependency ------------------------------------------------------
      excuse='\b(forgot|neglect\w*|chose not|did not bother|didn.t bother|cover(ed)? (it )?up|hid|hide|hiding)\b'
      why=$(prose_problem status_dependency "$dep")
      if [ -n "$why" ]; then
        fail=1
        echo "$why"
      elif asserts "$excuse" "$dep" || asserts "$load" "$dep"; then
        fail=1
        echo "not yet: status_dependency gives a reason the summary does not. AWS says"
        echo "         it could not update per-service status because of a dependency."
        echo "         Run ./replay.sh: the console fails to load. What does it load from?"
      elif has '\b(mov\w*|migrat\w*|relocat\w*)\b' "$dep" \
           && ! has '\b(multi-region|multiple regions|more than one region|(two|several|multiple) regions|across)\b' "$dep"; then
        fail=1
        echo "not yet: status_dependency moves the console to another region. That moves"
        echo "         the problem with it: an outage there is the one it cannot report."
        echo "         What lets it work when any one region is down?"
      else
        miss=""
        has '\b(status|dashboard|shd|console)\b' "$dep" || miss="status"
        { has '\bs3\b' "$dep" && has '\b(depend\w*|reli\w*|rely|relies|needed|needs|requires?|required|hosted|stored|backed|ran on|runs on|built on|loads?|loaded)\b' "$dep"; } || miss="$miss loop"
        has '\b(multi-region|multiple regions|more than one region|(another|other|second|separate|different|independent) (aws )?regions?|(across|in|into|to) (two|several|multiple|other) regions|outside (of )?(the region|us-east-1|s3)|independent of s3|off s3)\b' "$dep" || miss="$miss break"
        if [ -n "$miss" ]; then
          fail=1
          echo "not yet: status_dependency does not yet explain it. Say"
          case "$miss" in *status*) echo "         - what could not be updated," ;; esac
          case "$miss" in *loop*)   echo "         - what that depended on (status/console.conf says)," ;; esac
          case "$miss" in *break*)  echo "         - and what change lets it work when that is down." ;; esac
        fi
      fi

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the console posts status through an outage in any one region, the"
      echo "       removal tool cannot take a subsystem below its minimum or move more"
      echo "       than two servers at once, and the postmortem names both mechanisms."
