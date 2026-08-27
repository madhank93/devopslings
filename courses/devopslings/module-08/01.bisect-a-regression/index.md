---
kind: lesson
title: "the test passed sixty-five commits ago and fails now"
description: |
  A calculator worked and now returns the wrong answer, and the commit that
  broke it is somewhere in sixty-five of them. Reading every diff is the slow
  way; git bisect finds the exact commit by binary search in about six steps.
  The grader runs the same search itself, so only the real culprit passes.
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

      cat > calc.sh <<'C'
      #!/bin/sh
      echo $(( 6 * 7 ))
      C

      cat > test.sh <<'T'
      #!/bin/sh
      [ "$(sh calc.sh)" = "42" ]
      T

      chmod +x calc.sh test.sh

      git add -A
      git commit -q -m 'c0: initial calculator and test'
      git branch -M main

      for i in $(seq 1 64); do
        if [ "$i" = "41" ]; then
          sed -i.bak 's/6 \* 7/6 + 7/' calc.sh
          rm -f calc.sh.bak
          msg="c$i: simplify the arithmetic in calc.sh"
        else
          echo "note $i" >> notes.md
          msg="c$i: add note $i"
        fi
        git add -A
        git commit -q -m "$msg"
      done

      cat > questions.txt <<'Q'
      Somewhere in the last 65 commits, calc.sh stopped producing the right answer.
      At the tip of main the test fails:

        $ sh test.sh; echo $?
        1

      At the very first commit it passed. One commit in between turned a working
      calculator into a broken one, and reading 65 diffs to find it is the slow way.

      git bisect finds it by binary search: you mark one commit known-bad and one
      known-good, and git checks out the midpoint for you to test, halving the range
      each step. Sixty-five commits is about six steps, not sixty-five.

        $ git bisect start
        $ git bisect bad main
        $ git bisect good $(git rev-list --max-parents=0 main)
        $ git bisect run sh test.sh      # let the test drive each step
        ...
        <sha> is the first bad commit

      When you are done, `git bisect reset` returns you to where you started.

      Write bisect-answer.md with exactly two lines:

        first_bad_commit: <the short or full sha of the commit that broke the test>
        found_with: <the git command that locates it by binary search>
      Q

      echo "scenario ready — 65 commits, one of them broke the test"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e

      ans=bisect-answer.md

      if [ ! -s "$ans" ]; then
        echo "not yet: bisect-answer.md is missing or empty."
        echo "         Two lines: first_bad_commit and found_with. See questions.txt."
        exit 1
      fi

      # Ground truth: find the first bad commit ourselves, by the same binary
      # search the student runs. Leave the repo exactly as we found it.
      git bisect reset >/dev/null 2>&1 || true
      git checkout -q main 2>/dev/null || true
      first=$(git rev-list --max-parents=0 main 2>/dev/null)
      git bisect start >/dev/null 2>&1
      git bisect bad main >/dev/null 2>&1
      git bisect good "$first" >/dev/null 2>&1
      truth=$(git bisect run sh test.sh 2>/dev/null \
        | sed -n 's/^\([0-9a-f]\{40\}\) is the first bad commit.*/\1/p' | head -1)
      git bisect reset >/dev/null 2>&1
      git checkout -q main 2>/dev/null || true

      if [ -z "$truth" ]; then
        echo "not yet: the scenario could not be evaluated — the repository is not"
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

      # Normalise the student's answer to a full sha and compare. A short hash,
      # a full hash, or the commit ref all resolve the same way.
      a_full=$(git rev-parse --verify "${a_sha}^{commit}" 2>/dev/null || true)
      if [ -z "$a_full" ]; then
        echo "not yet: first_bad_commit '$a_sha' is not a commit in this repository."
        exit 1
      fi
      if [ "$a_full" != "$truth" ]; then
        echo "not yet: $a_sha is not the first bad commit."
        good_side=$(git merge-base --is-ancestor "$a_full" "$truth" 2>/dev/null && echo before || echo after)
        if [ "$good_side" = "before" ]; then
          echo "         That commit is still earlier than the break — the test"
          echo "         passes there. The bad one is after it."
        else
          echo "         That commit is after the break — the test already fails by"
          echo "         then. The first bad one is earlier. bisect reports the"
          echo "         boundary exactly; re-run it and read the sha it prints."
        fi
        exit 1
      fi

      if ! printf '%s' "$a_how" | grep -q 'bisect'; then
        echo "not yet: found_with says '${a_how:-nothing}'. Name the git command"
        echo "         that locates a regression by binary search."
        exit 1
      fi

      echo "PASS — $(git rev-parse --short "$truth") is the commit that broke the"
      echo "       test ($(git log -1 --format=%s "$truth")), found by bisect."
