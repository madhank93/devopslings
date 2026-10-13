---
kind: lesson
title: "seven of eight servers, and a flag that meant something else on the eighth"
description: |
  On 1 August 2012 one of Knight Capital's eight order-router servers was still
  running code the other seven had replaced, and a flag the new code had taken
  over still meant the old thing there. Reconstruct the divergence from the
  fleet, write the pre-open gate that would have refused to trade on it, and
  explain what the response did to the other seven.
name: incident-knight-capital-2012
slug: incident-knight-capital-2012
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
      mkdir -p answers fleet/release/smars fleet/previous/smars

      # ---- the two builds -------------------------------------------------
      #
      # Each host's "build" is one routine: what SMARS does with a parent
      # order that carries the flag. Argument 1 is the parent order's size,
      # argument 2 caps how many child orders a replay prints.
      cat > fleet/release/smars/on_flag <<'SH'
      #!/bin/sh
      # SMARS, RLP build. A parent order carrying the flag is handled by the
      # Retail Liquidity Program code: one child order for the parent's size.
      echo "RLP child qty=$1"
      SH

      cat > fleet/previous/smars/on_flag <<'SH'
      #!/bin/sh
      # SMARS, previous build. The flag activates Power Peg, unused since 2003.
      # Its cumulative-quantity tracking was moved earlier in the code path in
      # 2005, so this routine never learns that the parent order has filled.
      i=0
      while [ "$i" -lt "${2:-1000}" ]; do
        echo "POWER PEG child qty=$1"
        i=$((i + 1))
      done
      SH
      chmod +x fleet/release/smars/on_flag fleet/previous/smars/on_flag

      # ---- the fleet on the morning of 1 August ----------------------------
      : > fleet/inventory
      for n in 1 2 3 4 5 6 7 8; do
        echo "smars-$n" >> fleet/inventory
        mkdir -p "fleet/hosts/smars-$n"
        if [ "$n" -eq 8 ]; then
          cp -R fleet/previous/smars "fleet/hosts/smars-$n/"
        else
          cp -R fleet/release/smars "fleet/hosts/smars-$n/"
        fi
      done

      cat > fleet/deploy.log <<'LOG'
      # RLP deployment to SMARS. Reconstructed: the SEC order says the new code
      # was placed on a limited number of servers on successive days from
      # 27 July 2012. Which hosts went in which stage is illustrative.
      stage 1  smars-1  copy release/smars  ok
      stage 1  smars-2  copy release/smars  ok
      stage 2  smars-3  copy release/smars  ok
      stage 2  smars-4  copy release/smars  ok
      stage 3  smars-5  copy release/smars  ok
      stage 3  smars-6  copy release/smars  ok
      stage 3  smars-7  copy release/smars  ok
      deployment complete
      LOG

      cat > replay.sh <<'SH'
      #!/bin/sh
      # Send one flagged 100-share parent order to every host in a fleet's
      # inventory and count the child orders each one emits.
      # Usage: ./replay.sh [FLEET_DIR]     (default: fleet)
      fleet=${1:-fleet}
      while read -r h; do
        [ -n "$h" ] || continue
        if [ ! -x "$fleet/hosts/$h/smars/on_flag" ]; then
          echo "$h: no on_flag routine to run"
          continue
        fi
        n=$("$fleet/hosts/$h/smars/on_flag" 100 1000 | wc -l | tr -d ' ')
        first=$("$fleet/hosts/$h/smars/on_flag" 100 1 | cut -d' ' -f1,2)
        if [ "$n" -ge 1000 ]; then
          echo "$h: $first — $n child orders for a 100-share parent, and still sending"
        else
          echo "$h: $first — $n child order"
        fi
      done < "$fleet/inventory"
      SH
      chmod +x replay.sh

      # ---- the gate that existed -------------------------------------------
      cat > preflight.sh <<'SH'
      #!/usr/bin/env bash
      # Pre-open gate: runs before SMARS is allowed to trade.
      # Usage: ./preflight.sh FLEET_DIR
      # Exit 0 means "safe to trade". Anything else means "do not open", and
      # the output must name every host that is not safe.
      set -u
      fleet=${1:?usage: preflight.sh FLEET_DIR}

      # Every host the deploy touched reported ok.
      if grep -E '^stage' "$fleet/deploy.log" | grep -vq ' ok$'; then
        echo "REFUSE: a deploy step did not report ok"
        exit 1
      fi
      echo "deploy log clean — safe to trade"
      SH
      chmod +x preflight.sh

      cat > answers/reconstruction.md <<'MD'
      # One line per field. Replace each ? and keep each answer on its line.

      # Which server diverged from the others. One host name.
      divergent_host: ?

      # One stale server cost Knight more than $460 million. In a sentence or
      # two: what did the flag do on that server, and why only there?
      root_cause: ?

      # During the response, Knight took the new RLP code back off the servers
      # that had it. Replay that against the fleet. What did it do, and why?
      rollback: ?
      MD

      cat > incident.md <<'MD'
      # Knight Capital, 1 August 2012

      Source: SEC order, Release No. 34-70694, 16 October 2013. Paragraph numbers
      below are the order's. This reconstruction is simplified.

      - Knight's automated equity order router, SMARS, ran on eight servers. It
        takes "parent" orders and sends one or more "child" orders to trading
        venues. (¶12, ¶15)
      - For NYSE's Retail Liquidity Program, starting 1 August 2012, Knight wrote
        new RLP code for SMARS. It was meant to replace unused code for a
        function called Power Peg, which Knight had stopped using in 2003 but
        which was still present and callable. The new code also repurposed the
        flag that used to activate Power Peg. (¶13, ¶14)
      - In 2005 Knight moved Power Peg's cumulative-quantity tracking — the part
        that stops child orders once the parent is filled — to an earlier point
        in the code, and did not retest Power Peg afterwards. (¶14)
      - The new code was deployed in stages from 27 July. (¶15)
      - From about 08:01 ET on 1 August, an internal system sent automated
        e-mails referencing SMARS and an error described as "Power Peg
        disabled" — 97 of them before the 09:30 open. They were not designed as
        alerts and generally were not read. (¶19)
      - After the open, for 212 incoming parent orders, SMARS sent millions of
        child orders: over 4 million executions in 154 stocks, more than 397
        million shares, in about 45 minutes. Knight lost more than $460 million.
        (¶1, ¶17)

      The fleet as it stood that morning is in fleet/. What happened to it is
      yours to reconstruct.
      MD

      cat > questions.txt <<'Q'
      Read incident.md, then look at the fleet:

        fleet/inventory        the eight SMARS servers
        fleet/hosts/<host>/    what each one is running
        fleet/release/         the build every host was meant to have
        fleet/previous/        the build it replaced
        fleet/deploy.log       what the deployment reported

        ./replay.sh            one flagged order to every host

      Two things to do.

      1. preflight.sh is the gate that runs before SMARS may trade. It passed
         that morning. Make it a gate that would have refused: given a fleet
         directory, it exits 0 only when it is safe to turn the flag on, and
         otherwise exits non-zero and names every host that is not safe.

         The grader runs your preflight.sh against fleets of its own, not just
         this one — including healthy ones it must let through.

      2. Fill in answers/reconstruction.md: the divergent host, what the flag
         did there, and what the response's rollback did.
      Q

      echo "scenario ready in $(pwd)"
      echo
      echo "  incident.md                what the SEC order records"
      echo "  fleet/                     the eight servers as they stood on 1 August"
      echo "  ./replay.sh                send one flagged order to every host"
      echo "  preflight.sh               the pre-open gate — make it refuse"
      echo "  answers/reconstruction.md  the written half"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      ans=answers/reconstruction.md

      if [ ! -s preflight.sh ]; then
        echo "not yet: preflight.sh is missing or empty"
        exit 1
      fi

      # ---- the gate, against fleets the grader builds ----------------------
      #
      # Built from the grader's own copy of the two builds, so editing fleet/
      # changes nothing here.
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      mkdir -p "$work/release/smars" "$work/previous/smars"
      printf '#!/bin/sh\necho "RLP child qty=$1"\n' > "$work/release/smars/on_flag"
      printf '#!/bin/sh\ni=0\nwhile [ "$i" -lt "${2:-1000}" ]; do echo "POWER PEG child qty=$1"; i=$((i+1)); done\n' \
        > "$work/previous/smars/on_flag"
      chmod +x "$work/release/smars/on_flag" "$work/previous/smars/on_flag"

      # mkfleet NAME — eight hosts, all on the release build.
      mkfleet() {
        local d="$work/$1" n
        mkdir -p "$d/hosts"
        cp -R "$work/release" "$d/release"
        : > "$d/inventory"
        : > "$d/deploy.log"
        for n in 1 2 3 4 5 6 7 8; do
          echo "smars-$n" >> "$d/inventory"
          mkdir -p "$d/hosts/smars-$n"
          cp -R "$work/release/smars" "$d/hosts/smars-$n/"
          echo "stage 1  smars-$n  copy release/smars  ok" >> "$d/deploy.log"
        done
        echo "$d"
      }
      stale() { rm -rf "$1/hosts/$2/smars"; cp -R "$work/previous/smars" "$1/hosts/$2/"; }

      # run NAME — sets rc and out from the student's gate.
      run() {
        rc=0
        out=$(bash ./preflight.sh "$work/$1" 2>&1) || rc=$?
      }
      names() { grep -Eq "\b$1\b" <<<"$out"; }
      show() {
        if [ -z "$out" ]; then echo "           | (no output)"; else sed -n '1,8s/^/           | /p' <<<"$out"; fi
      }

      # The incident: the deploy log lists seven hosts, the eighth is stale.
      d=$(mkfleet incident)
      stale "$d" smars-8
      grep -v 'smars-8' "$d/deploy.log" > "$d/deploy.tmp"; mv "$d/deploy.tmp" "$d/deploy.log"
      run incident
      if [ "$rc" -eq 0 ]; then
        echo "not yet: preflight.sh passed the incident fleet, where smars-8 still has"
        echo "         the previous build. Its output:"
        show
        echo "         What a host is running is in fleet/hosts/<host>, and what it should"
        echo "         be running is in fleet/release. The deploy log is a third thing."
        exit 1
      fi
      if ! names smars-8; then
        echo "not yet: preflight.sh refused the incident fleet but did not name smars-8."
        show
        echo "         Whoever reads this at 09:29 needs to know which host to pull."
        exit 1
      fi
      for n in 1 2 3 4 5 6 7; do
        if names "smars-$n"; then
          echo "not yet: on the incident fleet preflight.sh named smars-$n, which matches"
          echo "         release/ exactly:"
          show
          echo "         A gate that names healthy hosts sends the on-call to the wrong one."
          exit 1
        fi
      done

      # A healthy fleet must open.
      mkfleet healthy >/dev/null
      run healthy
      if [ "$rc" -ne 0 ]; then
        echo "not yet: preflight.sh refused a fleet where all eight hosts match release/."
        show
        echo "         A gate that never opens gets bypassed, and then it catches nothing."
        exit 1
      fi

      # The log claims eight clean copies; smars-2 is stale anyway.
      d=$(mkfleet lying-log)
      stale "$d" smars-2
      run lying-log
      if [ "$rc" -eq 0 ] || ! names smars-2; then
        echo "not yet: deploy.log reports all eight hosts ok, smars-2 has the previous"
        echo "         build, and preflight.sh $( [ "$rc" -eq 0 ] && echo 'passed it' || echo 'did not name smars-2'):"
        show
        echo "         A deploy log records what the deploy attempted. Only the hosts can"
        echo "         say what they are running — every one of them."
        exit 1
      fi

      # A partial copy: smars-3 is missing the routine entirely.
      d=$(mkfleet partial)
      rm -f "$d/hosts/smars-3/smars/on_flag"
      run partial
      if [ "$rc" -eq 0 ] || ! names smars-3; then
        echo "not yet: smars-3 is missing smars/on_flag — a copy that stopped part-way —"
        echo "         and preflight.sh $( [ "$rc" -eq 0 ] && echo 'passed it' || echo 'did not name smars-3'):"
        show
        echo "         Check that every file in release/ is on the host, not just that"
        echo "         the files the host does have match."
        exit 1
      fi

      # An unreachable host: in the inventory, nothing to inspect.
      d=$(mkfleet unreachable)
      rm -rf "$d/hosts/smars-5"
      run unreachable
      if [ "$rc" -eq 0 ] || ! names smars-5; then
        echo "not yet: smars-5 is in the inventory and its directory does not exist — a"
        echo "         host that cannot be inspected — and preflight.sh $( [ "$rc" -eq 0 ] && echo 'passed it' || echo 'did not name smars-5'):"
        show
        echo "         A host you cannot check is one you cannot trust to trade. Work from"
        echo "         the inventory, and fail closed."
        exit 1
      fi

      # The deploy never ran: eight identical hosts, none on the release.
      d=$(mkfleet never-deployed)
      for n in 1 2 3 4 5 6 7 8; do stale "$d" "smars-$n"; done
      run never-deployed
      if [ "$rc" -eq 0 ]; then
        echo "not yet: preflight.sh passed a fleet where all eight hosts are identical to"
        echo "         each other and none of them matches release/:"
        show
        echo "         Agreement between hosts is not the same as running the release."
        echo "         Turn the flag on here and every host runs Power Peg."
        exit 1
      fi

      # ---- the reconstruction ---------------------------------------------
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty"
        exit 1
      fi

      field() { awk -v k="$1:" 'index($0, k) == 1 { sub(/^[^:]*:[ \t]*/, ""); print; exit }' "$ans"; }
      has() { grep -Eqi "$1" <<<"$2"; }

      # True when some sentence of $2 matches $1 and is not negated — so
      # "it was not human error" does not count as blaming a human.
      asserts() {
        local s
        while IFS= read -r s; do
          has "$1" "$s" || continue
          has "\b(not|never|no|nor|neither|rather than|instead of)\b|n't\b" "$s" && continue
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

      host=$(field divergent_host | tr 'A-Z' 'a-z' | tr -d ' \t')
      root=$(field root_cause)
      back=$(field rollback)

      for k in divergent_host root_cause rollback; do
        v=$(field "$k")
        if [ -z "$v" ] || [ "$v" = "?" ]; then
          echo "not yet: '$k:' in $ans is missing or still '?'"
          exit 1
        fi
      done

      fail=0

      if [ "$host" != "smars-8" ]; then
        fail=1
        echo "not yet: divergent_host is '$host'."
        case "$host" in
          *,*|*smars-*smars-*) echo "         One host. Diff each host against fleet/release." ;;
          *) echo "         Diff each host in fleet/inventory against fleet/release, and run"
             echo "         ./replay.sh." ;;
        esac
      fi

      blame='\b(human error|operator error|user error|careless\w*|negligen\w*|more careful|be careful|retrain\w*|fired|fire (the|him|her|them)|disciplin\w*|(technician|operator|engineer)(.s)? fault|(his|her|their) fault)\b'
      newbug='\b(new|rlp) code (was|is|had|has|contained) (a |an )?(bug|bugs|buggy|defect\w*|flaw\w*|broken|wrong|faulty)\b|\b(bug|defect|flaw) in the (new|rlp)\b'
      market='\bmarket data\b|\b(nyse|exchange|market) (glitch|bug|outage|error|fault|failure)\b|\bfat[- ]?finger\w*'
      capacity='\b(overload\w*|capacity|latency|network (failure|outage|problem|issue))\b'
      oldcode='\b(power ?peg|dead code|old code|unused code|legacy code|defunct|stale code|previous (build|code|version)|old (build|version|functionality|function|routine))\b'
      reuse='\b(repurpos\w*|reus\w*|re-us\w*|recycl\w*|same flag|(formerly|previously|once) (used|meant|activated|triggered)|used to (activate|trigger|mean|turn on|switch on)|old meaning|meant something else|(other|different|second) meaning|two meanings|still (activated|triggered|meant|called))\b'

      # ---- root_cause -------------------------------------------------------
      why=$(prose_problem root_cause "$root")
      if [ -n "$why" ]; then
        fail=1
        echo "$why"
      elif asserts "$blame" "$root"; then
        fail=1
        echo "not yet: root_cause puts it on the person who ran the deploy."
        echo "         The SEC order records that a technician did not copy the new code"
        echo "         to one server — and that no second technician reviewed it and no"
        echo "         written procedure required one (¶15, ¶26). A manual step with nothing"
        echo "         checking it will be missed again. Say what on that server turned the"
        echo "         miss into \$460 million."
      elif asserts "$newbug" "$root"; then
        fail=1
        echo "not yet: root_cause blames the new RLP code. ./replay.sh against fleet/"
        echo "         shows seven hosts running it and doing exactly what it should; the"
        echo "         order says those seven processed the RLP orders correctly (¶16)."
        echo "         Look at what the eighth was running instead."
      elif asserts "$market" "$root"; then
        fail=1
        echo "not yet: root_cause points outside Knight. The 212 parent orders were"
        echo "         ordinary customer orders (¶1, ¶17); the millions of child orders"
        echo "         came from one of Knight's own servers. Which one, running what?"
      elif asserts "$capacity" "$root"; then
        fail=1
        echo "not yet: root_cause describes load. Nothing was slow or saturated —"
        echo "         one server did exactly what its code said, very fast. Run"
        echo "         ./replay.sh and read the code it ran."
      else
        miss=""
        has "$oldcode" "$root" || miss="old"
        { has '\bflag\b' "$root" && has "$reuse" "$root"; } || miss="$miss flag"
        if [ -n "$miss" ]; then
          fail=1
          echo "not yet: root_cause does not yet explain the mechanism."
          if has '\b(copy|copied|forgot|missed|skipped|technician)\b' "$root"; then
            echo "         A missed copy is how smars-8 ended up different. The order"
            echo "         records more than one thing that made that difference expensive."
          fi
          case "$miss" in *old*)
            echo "         - What was still on smars-8, and still callable? Read"
            echo "           fleet/hosts/smars-8/smars/on_flag." ;;
          esac
          case "$miss" in *flag*)
            echo "         - Why did a flag meant for RLP reach that code at all? Say what"
            echo "           the flag had been used for before the new code took it over." ;;
          esac
        fi
      fi

      # ---- rollback ---------------------------------------------------------
      helped='\b(fixed|stopped|contained|resolved|solved|halted|ended|limited)\b.{0,25}\b(it|problem|issue|incident|orders|trading|bleeding|damage)\b|\b(helped|was correct|right call|worked)\b'
      spread='\b(all eight|all 8|eight servers|8 servers|every (server|host)|all (the |of the )?(servers|hosts)|all of them|everywhere|seven|7|other (servers|hosts)|remaining|worse\w*|spread\w*|more (servers|hosts))\b'
      why=$(prose_problem rollback "$back")
      if [ -n "$why" ]; then
        fail=1
        echo "$why"
      elif asserts "$helped" "$back"; then
        fail=1
        echo "not yet: rollback says taking the new code off helped. Do it: copy fleet/,"
        echo "         put fleet/previous/smars on every host, and run ./replay.sh against"
        echo "         the copy. The order says the action worsened the problem (¶27)."
      else
        miss=""
        has "$oldcode" "$back" || miss="old"
        has "$spread" "$back" || miss="$miss spread"
        has '\b(flag|flagged|orders?)\b' "$back" || miss="$miss flag"
        if [ -n "$miss" ]; then
          fail=1
          echo "not yet: rollback does not yet explain what removing the new code did."
          echo "         Replay it: copy fleet/, put fleet/previous/smars on every host, and"
          echo "         run ./replay.sh against the copy. Then say"
          case "$miss" in *old*)    echo "         - what code the other servers were left running," ;; esac
          case "$miss" in *spread*) echo "         - how many servers that put in the same state as smars-8," ;; esac
          case "$miss" in *flag*)   echo "         - and why incoming orders still reached that code." ;; esac
        fi
      fi

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the gate refuses a fleet that differs from the release, on any host"
      echo "       and in any way, and opens on one that matches; and the reconstruction"
      echo "       names the stale server, the reused flag, and what the rollback spread."
