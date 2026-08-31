---
kind: lesson
title: "the tests went green and the fix is gone"
description: |
  A hotfix on main and a branch cut before it changed the same function, and
  each added its own test. Resolving that conflict by taking one side whole
  removes the other side's change — and the test that covered it, so the suite
  goes green with the bug back in. The grader ignores the suite and checks the
  four behaviours itself, including the one that only works if both changes are
  applied in the right order.
name: rebase-or-merge
slug: rebase-or-merge
createdAt: "2026-08-30"

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

      git init -q .
      git config user.email dev@example.com
      git config user.name 'Dev'

      cat > pricing.sh <<'P'
      #!/bin/sh
      # discount_amount <subtotal> <percent>
      discount_amount() {
        sub=$1
        pct=$2
        echo $(( sub * pct / 100 ))
      }

      total() {
        echo $(( $1 - $(discount_amount "$1" "$2") ))
      }
      P

      cat > tests.sh <<'T'
      #!/bin/sh
      . ./pricing.sh
      fail=0
      check() { [ "$2" = "$3" ] || { echo "FAIL $1: got $2 want $3"; fail=1; }; }

      check plain "$(total 200 10)" 180
      exit $fail
      T

      chmod +x pricing.sh tests.sh
      git add -A
      git commit -q -m 'c0: pricing and tests'
      git branch -M main

      # The branch, cut before the hotfix: a tier bonus inside discount_amount.
      git checkout -q -b tiered-pricing

      cat > pricing.sh <<'P'
      #!/bin/sh
      # discount_amount <subtotal> <percent>
      discount_amount() {
        sub=$1
        pct=$2
        if [ "$sub" -ge 10000 ]; then
          pct=$(( pct + 10 ))
        fi
        echo $(( sub * pct / 100 ))
      }

      total() {
        echo $(( $1 - $(discount_amount "$1" "$2") ))
      }
      P

      cat > tests.sh <<'T'
      #!/bin/sh
      . ./pricing.sh
      fail=0
      check() { [ "$2" = "$3" ] || { echo "FAIL $1: got $2 want $3"; fail=1; }; }

      check plain "$(total 200 10)" 180
      check gold_tier "$(total 10000 20)" 7000
      exit $fail
      T

      git add -A
      git commit -q -m 'feat: gold-tier bonus of ten points over 10000'

      # The hotfix, landed on main after the branch was cut: same function.
      git checkout -q main

      cat > pricing.sh <<'P'
      #!/bin/sh
      # discount_amount <subtotal> <percent>
      discount_amount() {
        sub=$1
        pct=$2
        if [ "$pct" -gt 90 ]; then
          pct=90
        fi
        echo $(( sub * pct / 100 ))
      }

      total() {
        echo $(( $1 - $(discount_amount "$1" "$2") ))
      }
      P

      cat > tests.sh <<'T'
      #!/bin/sh
      . ./pricing.sh
      fail=0
      check() { [ "$2" = "$3" ] || { echo "FAIL $1: got $2 want $3"; fail=1; }; }

      check plain "$(total 200 10)" 180
      check clamp "$(total 200 150)" 20
      exit $fail
      T

      git add -A
      git commit -q -m 'fix: never discount more than ninety percent'

      cat > questions.txt <<'Q'
      Two people changed discount_amount() in pricing.sh.

      On main, a hotfix: stacked coupons had produced a percentage over 100 and a
      negative total, so any discount is now capped at 90 percent. It shipped with
      the test that catches it.

      On the branch tiered-pricing, cut before that hotfix landed: subtotals of
      10000 or more get ten extra points of discount. It has its own test.

      Both edits are in the same function, and both added a line to tests.sh, so
      integrating the branch conflicts in both files.

      1. Get tiered-pricing onto main so main's tip has both behaviours. The branch
         has not been shared with anyone, so merge or rebase is your call. The
         commit 'feat: gold-tier bonus of ten points over 10000' has to still be
         reachable from main afterwards — integrate it, do not retype the change
         onto main.

      2. Then write resolution.md with exactly three lines:

           integrated_with: <merge or rebase>
           ours_during_conflict: <which branch's version git called "ours">
           why: <one line: what taking one side whole would have dropped>

      A passing `sh tests.sh` does not mean you are done. Each side's test arrived
      in the same conflict as its code, so a resolution that drops one side drops
      the test that would have told you.
      Q

      echo "scenario ready — main has the clamp hotfix, tiered-pricing has the tier bonus"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e

      ans=resolution.md

      if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo none)" != main ]; then
        echo "not yet: check out main — the integrated result has to be on main."
        exit 1
      fi

      # Both sides' commits have to be reachable from main: the branch integrated
      # rather than retyped, and the hotfix still there rather than reset away.
      subjects=$(git log main --format='%s' 2>/dev/null || true)
      for want in 'feat: gold-tier bonus of ten points over 10000' \
                  'fix: never discount more than ninety percent'; do
        if ! printf '%s\n' "$subjects" | grep -Fqx "$want"; then
          echo "not yet: '$want' is not in main's history. Both sides' commits have to"
          echo "         survive the integration. Retyping the change onto main loses one;"
          echo "         so does resetting main onto a single side; and so does a"
          echo "         resolution that keeps one side whole — it leaves the replayed"
          echo "         commit with nothing in it, and an empty commit is dropped."
          exit 1
        fi
      done

      if [ ! -s tests.sh ]; then
        echo "not yet: tests.sh is missing or empty at the tip."
        exit 1
      fi
      tests=$(cat tests.sh)
      if ! printf '%s\n' "$tests" | grep -q 'check clamp'; then
        echo "not yet: tests.sh has no clamp test. It conflicted alongside the clamp"
        echo "         itself, so the resolution that dropped the test dropped the fix."
        echo "         A conflict in a list of tests is almost always resolved by"
        echo "         keeping both sides."
        exit 1
      fi
      if ! printf '%s\n' "$tests" | grep -q 'check gold_tier'; then
        echo "not yet: tests.sh has no gold_tier test. It conflicted alongside the tier"
        echo "         bonus itself, so the resolution that dropped the test dropped the"
        echo "         feature. A conflict in a list of tests is almost always resolved"
        echo "         by keeping both sides."
        exit 1
      fi

      # The real gate: the learner's own suite is not trusted, because the
      # resolution under test is the one that deletes tests. Call the function.
      if [ ! -s pricing.sh ]; then
        echo "not yet: pricing.sh is missing or empty at the tip."
        exit 1
      fi
      b() { sh -c ". ./pricing.sh; total $1 $2" 2>/dev/null || echo ERR; }

      got=$(b 200 10)
      if [ "$got" != 180 ]; then
        echo "not yet: total 200 10 gives $got, want 180. The ordinary case is broken —"
        echo "         the resolution changed more than the two conflicting edits."
        exit 1
      fi

      got=$(b 200 150)
      if [ "$got" != 20 ]; then
        echo "not yet: total 200 150 gives $got, want 20. The 90 percent cap from main"
        echo "         is gone, so a stacked coupon discounts more than the subtotal"
        echo "         again. That is the fix the conflict resolution dropped."
        exit 1
      fi

      got=$(b 10000 20)
      if [ "$got" != 7000 ]; then
        echo "not yet: total 10000 20 gives $got, want 7000. The tier bonus from"
        echo "         tiered-pricing is gone — the branch's side of the conflict was"
        echo "         discarded."
        exit 1
      fi

      got=$(b 10000 85)
      if [ "$got" != 1000 ]; then
        echo "not yet: total 10000 85 gives $got, want 1000. Both changes are present"
        echo "         but they run in the wrong order: the tier bonus is added to the"
        echo "         percentage first and the cap applies to the result, so 85 becomes"
        echo "         95 and then 90. Capping first leaves 85 alone, and the bonus"
        echo "         then lifts it to 95 — back over the cap the hotfix enforces."
        exit 1
      fi

      if [ ! -s "$ans" ]; then
        echo "not yet: resolution.md is missing or empty. Three lines: integrated_with,"
        echo "         ours_during_conflict, why."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      a_cmd=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*integrated_with[[:space:]]*[:=][[:space:]]*//p' | head -1)
      a_ours=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*ours_during_conflict[[:space:]]*[:=][[:space:]]*//p' | head -1)
      a_why=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*why[[:space:]]*[:=][[:space:]]*//p' | head -1)

      if ! printf '%s' "$a_cmd" | grep -qE 'merge|rebase'; then
        echo "not yet: integrated_with says '${a_cmd:-nothing}'. Name the command you"
        echo "         integrated with — merge or rebase."
        exit 1
      fi
      if ! printf '%s' "$a_ours" | grep -q 'main'; then
        echo "not yet: ours_during_conflict says '${a_ours:-nothing}'. In a rebase, 'ours'"
        echo "         is the branch you are replaying onto — main — and 'theirs' is your"
        echo "         own commit being replayed, which is the reverse of what the words"
        echo "         suggest when you are standing on the feature branch. Merging"
        echo "         tiered-pricing while on main makes 'ours' main as well."
        exit 1
      fi
      if ! printf '%s' "$a_why" | grep -qE 'clamp|cap|hotfix|fix|drop|lose|lost|discard|overwrit|test'; then
        echo "not yet: why says '${a_why:-nothing}'. Say what taking one side whole would"
        echo "         have thrown away."
        exit 1
      fi

      echo "PASS — both commits are in main's history, both tests survived the"
      echo "       conflict, and all four behaviours are right, bonus before cap."
