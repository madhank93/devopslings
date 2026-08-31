---
kind: lesson
title: "the loop, done once so the history says what happened"
description: |
  Branch, commit, merge — the loop everything else in this module operates on.
  Done by default it fast-forwards, which replays your commits onto main and
  leaves no trace that a branch ever existed. The grader requires a merge commit
  with the branch's work on its second parent, and asks what that commit records
  that a fast-forward does not.
name: branch-commit-merge
slug: branch-commit-merge
createdAt: "2026-08-31"

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

      cat > README.md <<'F'
      # payments-api

      The service that takes the money. Deployed from main.
      F

      cat > app.py <<'F'
      def charge(amount):
          return gateway.post(amount)
      F

      git add -A
      git commit -q -m 'c0: payments-api'
      git branch -M main

      cat > questions.txt <<'Q'
      This is the loop the rest of the module operates on, done once, properly.

      The service has no health check. Add one on a branch, and land it on main so
      that main's history says a branch happened.

      1. Create a branch called add-healthcheck and switch to it.

      2. On that branch, add a file healthcheck.sh containing:

           #!/bin/sh
           curl -sf http://localhost:8080/health

         and commit it with exactly this subject:

           feat: add healthcheck script

      3. Still on the branch, add a line to README.md mentioning healthcheck.sh,
         and commit it with exactly this subject:

           docs: document the healthcheck

      4. Merge the branch into main.

         Read this part before you run it. main has not moved since you branched,
         so git's default is a fast-forward: it slides main's pointer up to the
         branch tip. You get your two commits and nothing else — no record that
         they were ever a branch, and nothing marking the moment they landed. The
         merge has to be recorded instead. Look up what --no-ff does.

      5. Write merge.md with exactly three lines:

           parents: <how many parent commits does main's tip have now>
           fast_forward: <what a fast-forward would have left in the history instead>
           records: <one line: what the merge commit records that a fast-forward does not>
      Q

      echo "scenario ready — payments-api on main, one commit, no branch yet"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e

      ans=merge.md
      feat='feat: add healthcheck script'
      docs='docs: document the healthcheck'

      if [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo none)" != main ]; then
        echo "not yet: check out main — the merged result has to be on main."
        exit 1
      fi

      if ! git cat-file -e HEAD:healthcheck.sh 2>/dev/null; then
        echo "not yet: healthcheck.sh is not in main's tree. Add it on the branch and"
        echo "         merge the branch into main."
        exit 1
      fi

      # A merge commit has two parents, so rev-list prints three fields: the
      # commit and both of them.
      nparents=$(git rev-list --parents -n 1 HEAD | wc -w | tr -d ' ')
      if [ "$nparents" != 3 ]; then
        # Say which of the three ways to get here happened, rather than guessing.
        subjects=$(git log --format='%s' 2>/dev/null || true)
        if printf '%s\n' "$subjects" | grep -Fqx "$feat" && printf '%s\n' "$subjects" | grep -Fqx "$docs"; then
          if git rev-parse --verify -q add-healthcheck >/dev/null 2>&1; then
            echo "not yet: both commits are on main, in a straight line, and main's tip has"
            echo "         one parent. The branch still exists and main has reached its tip"
            echo "         without a merge commit, which is the fast-forward: git moved"
            echo "         main's pointer up instead of recording a merge. Reset main back"
            echo "         to the first commit and merge again with --no-ff."
          else
            echo "not yet: both commits are on main, in a straight line, and main's tip has"
            echo "         one parent — and there is no add-healthcheck branch. Whether the"
            echo "         commits were made straight onto main or the merge fast-forwarded,"
            echo "         the result is the same: nothing in this history records that the"
            echo "         work was a branch. Do the two commits on add-healthcheck and"
            echo "         merge it with --no-ff."
          fi
        else
          echo "not yet: main's tip has one parent and the branch's commit subjects are"
          echo "         not in its history. The two commits belong on add-healthcheck,"
          echo "         and main gets them by merging that branch — not by committing"
          echo "         the same files again, and not with --squash, which flattens both"
          echo "         commits into one and keeps a single parent."
        fi
        exit 1
      fi

      # The branch side of the merge is the second parent. Both commits have to
      # be there, which is what makes this a merge of the branch rather than of
      # something reconstructed by hand.
      branch_side=$(git log --format='%s' HEAD^2 2>/dev/null || true)
      for want in "$feat" "$docs"; do
        if ! printf '%s\n' "$branch_side" | grep -Fqx "$want"; then
          echo "not yet: main's tip is a merge commit, but '$want' is not on its second"
          echo "         parent — the branch side. The two commits have to be made on"
          echo "         add-healthcheck and merged from there, with those subjects"
          echo "         exactly."
          exit 1
        fi
      done

      if ! git show HEAD:healthcheck.sh 2>/dev/null | grep -q '/health'; then
        echo "not yet: healthcheck.sh does not request the /health endpoint."
        exit 1
      fi
      if ! git show HEAD:README.md 2>/dev/null | grep -q 'healthcheck.sh'; then
        echo "not yet: README.md at the tip does not mention healthcheck.sh. That was"
        echo "         the second commit on the branch."
        exit 1
      fi

      if [ ! -s "$ans" ]; then
        echo "not yet: merge.md is missing or empty. Three lines: parents,"
        echo "         fast_forward, records."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      a_par=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*parents[[:space:]]*[:=][[:space:]]*//p' | head -1)
      a_ff=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*fast_forward[[:space:]]*[:=][[:space:]]*//p' | head -1)
      a_rec=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*records[[:space:]]*[:=][[:space:]]*//p' | head -1)

      if ! printf '%s' "$a_par" | grep -qE '(^| )2( |$)|two'; then
        echo "not yet: parents says '${a_par:-nothing}'. Count them:"
        echo "         git rev-list --parents -n 1 HEAD"
        exit 1
      fi
      if ! printf '%s' "$a_ff" | grep -qE 'linear|straight|line|no merge|without a merge|nothing|one parent|pointer|moves|no record|no trace'; then
        echo "not yet: fast_forward says '${a_ff:-nothing}'. Describe the history a"
        echo "         fast-forward leaves behind — its shape, and what is missing"
        echo "         from it."
        exit 1
      fi
      if ! printf '%s' "$a_rec" | grep -qE 'branch|second parent|two parent|when|integrat|land|merge point|group|together|who|boundary'; then
        echo "not yet: records says '${a_rec:-nothing}'. Name what the merge commit"
        echo "         holds that a straight line cannot: where the commits came from,"
        echo "         and when they landed."
        exit 1
      fi

      echo "PASS — main's tip is a merge commit, both branch commits are on its"
      echo "       second parent, and the answer says what that records."
