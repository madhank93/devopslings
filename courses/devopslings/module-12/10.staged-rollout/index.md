---
kind: lesson
title: "the bad rule reached every node in forty seconds"
description: |
  A config change went to 100% of the fleet at once and took the service down
  globally. Design the rollout that would have stopped it at the canary — the
  stages, the signal, the bake time, and what happens to the nodes already
  changed — and the grader runs your policy against the change that broke it.
name: staged-rollout
slug: staged-rollout
createdAt: "2026-09-03"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      set -e

      rm -rf ./* ./.[!.]* 2>/dev/null || true
      mkdir -p answers

      cat > incident.md <<'MD'
      # Incident: global outage, 2019-07-02

      A new WAF rule was published to the edge fleet. The rule contained a
      pattern that backtracks catastrophically, so every request that reached a
      node running it burned CPU. Within forty seconds every node in the fleet
      was at 100% CPU and the service was down worldwide.

      The rule was correct in review, correct in the test suite, and fatal in
      production, because the cost only appears against real traffic.

      ## How it was deployed

      One step. `rollout.sh` writes the rule to all 100 nodes and exits.

      ## What the signals did

      - `cpu_p95` across the fleet went from 41 to 97 on any node that had the
        rule, and took about thirty seconds of real traffic to get there.
      - `http_5xx_per_10k` did **not** move. The rule made requests expensive,
        not wrong — nodes kept returning 200s until they saturated completely,
        which happened after the rollout had already finished.

      ## What you are designing

      Not a faster rollback. A rollout that could not have reached 100%.
      MD

      cat > rollout.sh <<'SH'
      #!/bin/sh
      # How the rule was shipped. One stage, whole fleet, no gate.
      set -eu
      for node in $(seq 1 100); do
        printf 'node-%s: applied %s\n' "$node" "$1"
      done
      echo "rollout complete: 100 nodes"
      SH
      chmod +x rollout.sh

      # A copy of the harness for your own experiments. The grader runs its own
      # copy against your policy.env, so editing this one proves nothing.
      cat > simulate.sh <<'SH'
      #!/bin/sh
      # Walk the stages in policy.env against a recorded change and report
      # where the rollout stopped. Usage: ./simulate.sh bad|healthy
      set -eu

      change=${1:?usage: simulate.sh bad|healthy}
      . ./policy.env

      # What the named signal reads on a node that already has the change.
      # cpu_p95 needs about thirty seconds of traffic before the cost shows up;
      # the error rate never separates the two, because the rule makes requests
      # expensive rather than wrong.
      signal_for() {
        case "$SIGNAL" in
          cpu_p95)
            if [ "$BAKE_SECONDS" -lt 30 ]; then echo 41; return; fi
            case "$change" in bad) echo 97 ;; *) echo 41 ;; esac
            ;;
          http_5xx_per_10k)
            echo 10
            ;;
          *)
            echo "unknown signal: $SIGNAL" >&2
            exit 2
            ;;
        esac
      }

      stage_no=0
      applied=0
      for pct in $(echo "$STAGES" | tr ',' ' '); do
        stage_no=$((stage_no + 1))
        applied=$((100 * pct / 100))
        reading=$(signal_for)
        if [ "$reading" -gt "$THRESHOLD" ]; then
          echo "HALTED stage=$stage_no applied=$applied signal=$SIGNAL reading=$reading"
          exit 0
        fi
      done
      echo "COMPLETED applied=$applied"
      SH
      chmod +x simulate.sh

      cat > policy.env <<'ENV'
      # The rollout policy. Replace every ? and keep the shell syntax valid —
      # both the harness and the grader read this file with `.`.

      # Cumulative percentage of the fleet after each stage, increasing, ending
      # at 100. "1,5,25,100" means: one node, then five, then twenty-five, then
      # all of them.
      STAGES=?

      # Which signal gates promotion. The recorded ones are cpu_p95 and
      # http_5xx_per_10k.
      SIGNAL=?

      # Abort the rollout when the signal reads above this.
      THRESHOLD=?

      # How long to watch the signal before promoting to the next stage.
      BAKE_SECONDS=?
      ENV

      cat > answers/rollout.md <<'MD'
      # Rollout design

      # One of: revert | freeze | drain
      # What happens to the nodes that already have the change when a stage
      # fails its gate.
      abort-action: ?

      # Why this signal and not the other one. Name what the other one would
      # have done during this incident.
      signal: ?

      # What this rollout costs. A change that used to be live in forty seconds
      # now takes how long, and who pays for that?
      cost: ?

      # "We should just roll back faster" was the first suggestion in the
      # postmortem. Say why it is not a fix for this.
      why-not-faster-rollback: ?
      MD

      echo "scenario ready in $(pwd)"
      echo
      echo "  incident.md   what happened, and what the signals did"
      echo "  rollout.sh    how the rule was shipped"
      echo "  policy.env    your rollout policy — fill this in"
      echo "  simulate.sh   ./simulate.sh bad   and   ./simulate.sh healthy"
      echo "  answers/rollout.md   the written half"
      echo
      echo "Your policy has to stop the bad change at the canary AND still ship"
      echo "the healthy one to the whole fleet."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      pol=./policy.env
      ans=./answers/rollout.md

      if [ ! -s "$pol" ]; then
        echo "not yet: policy.env is missing or empty"
        exit 1
      fi
      if grep -q '=?' "$pol" 2>/dev/null; then
        echo "not yet: policy.env still has unfilled '?' values"
        exit 1
      fi

      # shellcheck disable=SC1090
      . "$pol" 2>/dev/null || {
        echo "not yet: policy.env is not valid shell — the harness reads it with '.'"
        exit 1
      }

      for k in STAGES SIGNAL THRESHOLD BAKE_SECONDS; do
        eval "v=\${$k:-}"
        if [ -z "$v" ]; then
          echo "not yet: $k is not set in policy.env"
          exit 1
        fi
      done

      case "$THRESHOLD" in ''|*[!0-9]*) echo "not yet: THRESHOLD must be a whole number"; exit 1 ;; esac
      case "$BAKE_SECONDS" in ''|*[!0-9]*) echo "not yet: BAKE_SECONDS must be a whole number"; exit 1 ;; esac

      first=""
      last=""
      prev=0
      for pct in $(echo "$STAGES" | tr ',' ' '); do
        case "$pct" in ''|*[!0-9]*) echo "not yet: STAGES must be whole numbers separated by commas"; exit 1 ;; esac
        [ -z "$first" ] && first=$pct
        if [ "$pct" -le "$prev" ]; then
          echo "not yet: STAGES must increase — '$STAGES' does not. They are cumulative"
          echo "percentages of the fleet, so each one is larger than the one before."
          exit 1
        fi
        prev=$pct
        last=$pct
      done

      if [ "$last" -ne 100 ]; then
        echo "not yet: STAGES ends at ${last}%, so the change never reaches the whole"
        echo "fleet. A rollout that stops short is not a rollout."
        exit 1
      fi

      if [ "$first" -gt 5 ]; then
        echo "not yet: the first stage is ${first}% of the fleet. That is not a canary —"
        echo "it is the blast radius you are choosing to accept before anything has"
        echo "been observed at all. Make it small enough that being wrong is cheap."
        exit 1
      fi

      # The grader runs its own harness, so editing the shipped simulate.sh
      # changes nothing here.
      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      cat > "$work/sim.sh" <<'SH'
      #!/bin/sh
      set -eu
      change=$1
      . ./policy.env
      signal_for() {
        case "$SIGNAL" in
          cpu_p95)
            if [ "$BAKE_SECONDS" -lt 30 ]; then echo 41; return; fi
            case "$change" in bad) echo 97 ;; *) echo 41 ;; esac
            ;;
          http_5xx_per_10k) echo 10 ;;
          *) echo "unknown-signal"; exit 2 ;;
        esac
      }
      stage_no=0
      applied=0
      for pct in $(echo "$STAGES" | tr ',' ' '); do
        stage_no=$((stage_no + 1))
        applied=$pct
        reading=$(signal_for)
        if [ "$reading" -gt "$THRESHOLD" ]; then
          echo "HALTED stage=$stage_no applied=$applied reading=$reading"
          exit 0
        fi
      done
      echo "COMPLETED applied=$applied"
      SH
      chmod +x "$work/sim.sh"

      bad=$(sh "$work/sim.sh" bad 2>&1 || true)
      healthy=$(sh "$work/sim.sh" healthy 2>&1 || true)

      case "$bad" in
        *unknown-signal*)
          echo "not yet: SIGNAL='$SIGNAL' is not one of the recorded signals."
          echo "The recorded ones are cpu_p95 and http_5xx_per_10k."
          exit 1
          ;;
      esac

      case "$bad" in
        HALTED*) ;;
        *)
          echo "not yet: the bad change rolled out to the whole fleet — '$bad'."
          if [ "$SIGNAL" = "http_5xx_per_10k" ]; then
            echo "You are gating on the error rate. During this incident it did not move:"
            echo "the rule made requests expensive, not wrong, so nodes kept returning"
            echo "200s right up until they saturated — which was after every node had it."
            echo "A gate on a signal that does not respond to the failure is not a gate."
          elif [ "$BAKE_SECONDS" -lt 30 ]; then
            echo "BAKE_SECONDS is ${BAKE_SECONDS}. The CPU cost only appears after about"
            echo "thirty seconds of real traffic, so a stage that promotes sooner than"
            echo "that reads a healthy node and moves on. Bake time is how long the"
            echo "signal needs, not how long you are willing to wait."
          else
            echo "THRESHOLD is ${THRESHOLD} and the bad change drives cpu_p95 to 97."
          fi
          exit 1
          ;;
      esac

      bad_applied=$(printf '%s' "$bad" | sed -n 's/.*applied=\([0-9]*\).*/\1/p')
      if [ "${bad_applied:-100}" -gt 5 ]; then
        echo "not yet: the rollout halted, but only after reaching ${bad_applied}% of the"
        echo "fleet. Halting is worth what it saved — the gate has to run at the end of"
        echo "the first, small stage."
        exit 1
      fi

      case "$healthy" in
        COMPLETED*) ;;
        *)
          echo "not yet: the healthy change did not reach the fleet — '$healthy'."
          echo "THRESHOLD is ${THRESHOLD} and a healthy node reads 41 on cpu_p95. A gate"
          echo "that stops good changes too is not a safer rollout, it is an outage you"
          echo "scheduled yourself, and the team will route around it within a month."
          exit 1
          ;;
      esac

      if [ ! -s "$ans" ]; then
        echo "not yet: answers/rollout.md is missing or empty"
        exit 1
      fi
      if grep -q ': *?$' "$ans" 2>/dev/null; then
        echo "not yet: answers/rollout.md still has unanswered '?' fields"
        exit 1
      fi

      action=$(grep -E '^abort-action:' "$ans" 2>/dev/null | head -1 \
                 | sed 's/^abort-action: *//' | tr 'A-Z' 'a-z' | tr -d ' ' || true)
      case "$action" in
        revert) ;;
        freeze)
          echo "not yet: abort-action 'freeze' stops the rollout and leaves the canary"
          echo "nodes running the change that just failed its gate. The gate fired"
          echo "because those nodes are unhealthy; a halt that leaves them that way has"
          echo "converted a global outage into a permanent partial one."
          exit 1
          ;;
        drain)
          echo "not yet: abort-action 'drain' takes the canary nodes out of service."
          echo "That stops the bleeding and it also removes capacity during an incident,"
          echo "and the nodes still carry the bad change when they come back. What you"
          echo "want is for them to stop having it."
          exit 1
          ;;
        *)
          echo "not yet: abort-action must be one of revert, freeze, drain — got"
          echo "'${action:-nothing}'."
          exit 1
          ;;
      esac

      check_prose() {
        _field=$1
        _min=$2
        _body=$(grep -E "^${_field}:" "$ans" 2>/dev/null | head -1 | sed "s/^${_field}: *//" || true)
        _len=$(printf '%s' "$_body" | tr -d '[:space:]' | wc -c | tr -d ' ')
        if [ "${_len:-0}" -lt "$_min" ]; then
          echo "not yet: '${_field}:' is missing or too short to be an answer."
          return 1
        fi
        return 0
      }

      fail=0
      check_prose signal 60 || { echo "         Say why your signal and what the other one did during this"; echo "         incident. One of them was flat throughout."; fail=1; }
      check_prose cost 60 || { echo "         Every stage you add is time the change is not live. Say what the"; echo "         rollout now costs end to end, and who is waiting on it."; fail=1; }
      check_prose why-not-faster-rollback 60 || { echo "         Rollback speed is measured from when you know. Say what that means"; echo "         for a change that reaches every node in forty seconds."; fail=1; }

      [ "$fail" -ne 0 ] && exit 1

      echo "PASS — the bad change stops at ${bad_applied}% of the fleet, the healthy one"
      echo "ships to all of it, and the canary nodes are reverted rather than left."
---
