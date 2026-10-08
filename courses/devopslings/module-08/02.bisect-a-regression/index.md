---
kind: lesson
title: "checkout totals were right two hundred commits ago"
description: |
  The checkout total is a cent short, and the commit that broke it is one of
  two hundred. git bisect finds it in about eight steps, but only if the test
  driving it can tell "wrong answer" from "doesn't run", because two stretches
  of that history don't run at all. The grader replays your test under
  git bisect run, so a lucky guess doesn't pass.
name: bisect-a-regression
slug: bisect-a-regression
createdAt: "2026-08-27"

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

      git init -q .
      git config user.email dev@example.com
      git config user.name 'Dev'
      git config advice.detachedHead false

      mkdir lib
      cat > total.sh <<'S'
      #!/bin/sh
      # Usage: sh total.sh [cart]   prints the cart total, tax included.
      set -e
      . ./lib/money.sh
      . ./lib/tax.sh
      sub=0
      while read -r item price qty; do
        sub=$(( sub + $(line_total "$price" "$qty") ))
      done < "${1:-cart.txt}"
      cents "$(with_tax "$sub")"
      S
      cat > lib/money.sh <<'S'
      line_total() { echo $(( $1 * $2 )); }
      cents() { printf '%d.%02d\n' $(( $1 / 100 )) $(( $1 % 100 )); }
      S
      cat > lib/tax.sh <<'S'
      TAX_PCT=108
      # Round half up to the nearest cent.
      with_tax() { echo $(( ($1 * TAX_PCT + 50) / 100 )); }
      S
      cat > cart.txt <<'S'
      widget 1250 3
      gadget 899 2
      cable 150 4
      S
      printf '# checkout\n\nPrices are integer cents.\n' > README.md

      git add -A
      git commit -q -m 'c0: checkout total with tax'
      git branch -M main

      # c60 looks guilty and is harmless. c85-c115 and c140-c175 do not run at
      # all. c130 is the real regression, placed so that a test treating
      # "doesn't run" as bad (or as good) makes bisect land on a span edge.
      for i in $(seq 1 199); do
        case $i in
          60)
            cat > lib/money.sh <<'S'
      line_total() { echo $(( $1 * $2 )); }
      cents() {
        d=$(( $1 / 100 ))
        c=$(( $1 % 100 ))
        printf '%d.%02d\n' "$d" "$c"
      }
      S
            msg="c$i: rewrite cents() rounding (quick hack, please double-check)" ;;
          85)
            printf 'fmt_line() {\n  printf "%%s %%s\\n" "$1" "$(cents "$2")"\n' >> lib/money.sh
            msg="c$i: start fmt_line helper for receipts" ;;
          116)
            printf '}\n' >> lib/money.sh
            msg="c$i: finish fmt_line helper" ;;
          130)
            printf 'with_tax() { echo $(( $1 * 108 / 100 )); }\n' > lib/tax.sh
            msg="c$i: inline TAX_PCT" ;;
          140)
            git mv lib/tax.sh lib/rates.sh
            msg="c$i: move tax rules to lib/rates.sh" ;;
          176)
            sed 's#lib/tax.sh#lib/rates.sh#' total.sh > total.sh.new
            mv total.sh.new total.sh
            msg="c$i: source lib/rates.sh in total.sh" ;;
          *)
            echo "- note $i" >> README.md
            msg="c$i: docs: note $i" ;;
        esac
        git add -A
        git commit -q -m "$msg"
      done

      cat > questions.txt <<'Q'
      Checkout totals are a cent short. For the sample cart, at the tip of main:

        $ sh total.sh cart.txt
        66.39

      Finance reconciles that cart at 66.40, and at the first commit on main
      that is what it printed. There are 200 commits between then and now.

      Leave two files here:

        bisect-test.sh    a test git bisect run can drive: it decides whether
                          the checked-out commit is good or bad. The grader
                          replays it under `git bisect run`, bad = main,
                          good = the first commit, and it has to land on the
                          same commit you name.

        bisect-answer.md  exactly two lines:
                            first_bad_commit: <sha of the commit that broke it>
                            found_with: <the git command you ran to find it>
      Q

      echo "scenario ready: 200 commits, one of them broke the checkout total"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e

      ans=bisect-answer.md
      script=bisect-test.sh

      if [ ! -s "$ans" ]; then
        echo "not yet: bisect-answer.md is missing or empty."
        echo "         Two lines: first_bad_commit and found_with. See questions.txt."
        exit 1
      fi
      if [ ! -s "$script" ]; then
        echo "not yet: bisect-test.sh is missing or empty. The grader replays your"
        echo "         test under git bisect run, so it has to be a file here."
        exit 1
      fi

      git bisect reset >/dev/null 2>&1 || true
      git checkout -q main 2>/dev/null || true
      root=$(git rev-list --max-parents=0 main 2>/dev/null || true)
      tmp=$(mktemp -d)
      trap 'rm -rf "$tmp"' EXIT

      # probe <commit>: run that commit's total.sh in a scratch copy of its
      # tree, leaving the repo alone. Sets rc and out.
      probe() {
        rm -rf "$tmp/tree"; mkdir "$tmp/tree"
        git archive "$1" | tar -x -C "$tmp/tree"
        rc=0
        out=$(cd "$tmp/tree" && sh total.sh cart.txt 2>/dev/null) || rc=$?
      }

      # landed <cmd...>: the commit `git bisect run <cmd>` names as first bad
      # between the root and main, or nothing if it did not narrow to one.
      landed() {
        git bisect start main "$root" >/dev/null 2>&1
        if EXPECTED="$expected" git bisect run "$@" > "$tmp/run.log" 2>&1 \
           && grep -q 'is the first bad commit' "$tmp/run.log"; then
          git rev-parse refs/bisect/bad
        fi
        git bisect reset >/dev/null 2>&1
        git checkout -q main 2>/dev/null || true
      }

      # explain <commit>: what that commit shows, for a wrong landing.
      explain() {
        probe "$1"
        if [ "$rc" -ne 0 ]; then
          echo "         At that commit total.sh does not run at all (exit $rc): it can"
          echo "         say neither good nor bad. That is a span of history broken for"
          echo "         an unrelated reason. What should a bisect test return when it"
          echo "         can't test a commit?"
        elif [ "$out" = "$expected" ]; then
          echo "         At that commit the sample cart still totals $out, which is"
          echo "         right. The break comes later."
        else
          bad_out=$out
          probe "$1^"
          if [ "$rc" -ne 0 ]; then
            echo "         That commit prints $bad_out, but the one before it cannot run"
            echo "         total.sh at all (exit $rc), so nothing shows the break happened"
            echo "         here rather than earlier. What should a bisect test return"
            echo "         when it can't test a commit?"
          else
            echo "         That commit already prints $bad_out. The break is earlier."
          fi
        fi
      }

      expected=""
      [ -n "$root" ] && probe "$root" && [ "$rc" -eq 0 ] && expected=$out
      cat > "$tmp/truth.sh" <<'T'
      out=$(sh total.sh cart.txt 2>/dev/null) || exit 125
      [ "$out" = "$EXPECTED" ]
      T
      truth=""
      [ -n "$expected" ] && truth=$(landed sh "$tmp/truth.sh")
      if [ -z "$truth" ]; then
        echo "not yet: the scenario could not be evaluated: the repository is not"
        echo "         in the state init_scenario left it. Re-run the lesson."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < "$ans")
      a_sha=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*first_bad_commit[[:space:]]*[:=][[:space:]]*\([0-9a-f]*\).*/\1/p' | head -1)
      a_how=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*found_with[[:space:]]*[:=][[:space:]]*//p' | head -1)

      if [ -z "$a_sha" ]; then
        echo "not yet: first_bad_commit is missing or is not a commit hash."
        exit 1
      fi
      a_full=$(git rev-parse --verify -q "${a_sha}^{commit}" 2>/dev/null || true)
      if [ -z "$a_full" ]; then
        echo "not yet: first_bad_commit '$a_sha' is not a commit in this repository."
        exit 1
      fi
      if [ "$a_full" != "$truth" ]; then
        echo "not yet: $a_sha ($(git log -1 --format=%s "$a_full")) is not the first bad commit."
        explain "$a_full"
        exit 1
      fi

      # Replay the student's test from a copy, so checkouts can't touch it.
      cp -p "$script" "$tmp/student.sh"
      if [ -x "$tmp/student.sh" ] && [ "$(head -c 2 "$tmp/student.sh")" = '#!' ]; then
        s_hit=$(landed "$tmp/student.sh")
      else
        s_hit=$(landed sh "$tmp/student.sh")
      fi
      if [ -z "$s_hit" ]; then
        echo "not yet: your answer is right, but git bisect run with bisect-test.sh"
        echo "         (bad = main, good = the first commit) did not name a single"
        echo "         first bad commit. Its last words:"
        tail -3 "$tmp/run.log" 2>/dev/null | sed 's/^/           /'
        exit 1
      fi
      if [ "$s_hit" != "$truth" ]; then
        echo "not yet: your answer is right, but git bisect run with bisect-test.sh"
        echo "         lands on $(git rev-parse --short "$s_hit") ($(git log -1 --format=%s "$s_hit"))."
        explain "$s_hit"
        exit 1
      fi

      if ! printf '%s' "$a_how" | grep -Eq 'bisect[[:space:]]+run'; then
        echo "not yet: found_with says '${a_how:-nothing}'. Name the git command"
        echo "         that ran your test at each step of the binary search."
        exit 1
      fi

      echo "PASS: $(git rev-parse --short "$truth") ($(git log -1 --format=%s "$truth"))"
      echo "      broke the total, and bisect-test.sh finds it under git bisect run."
