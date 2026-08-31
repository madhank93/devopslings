---
kind: lesson
title: "A live token, deleted three weeks ago and still in every clone"
description: |
  A payment gateway token was committed in deploy/config.yml, and a later commit
  removed the file. It is not at the tip and it is not on disk, but it is in the
  history, so every clone still carries it. Getting it out means rewriting the
  commits that contain it — and the rewrite has a second half that is easy to
  miss. Removing it is also not the fix on its own: the token has been out.
name: secret-in-history
slug: secret-in-history
createdAt: "2026-08-29"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      set -e

      # Wipe the working directory
      rm -rf ./* ./.[!.]* 2>/dev/null || true

      git init -q .
      git config user.email dev@example.com
      git config user.name 'Dev'

      w() { mkdir -p "$(dirname "$1")"; printf '%s\n' "$2" > "$1"; }

      w README.md 'payments-api'
      w app.py 'def charge(amount): return gateway.post(amount)'
      git add -A
      git commit -q -m 'c0: initial payments-api'
      git branch -M main

      w handler_1.py 'handler 1'
      git add -A && git commit -q -m 'feat: handler 1'
      w handler_2.py 'handler 2'
      git add -A && git commit -q -m 'feat: handler 2'

      # The mistake: a live gateway token committed alongside ordinary config.
      mkdir -p deploy
      cat > deploy/config.yml <<'CFG'
      gateway_url: https://pay.example.com
      api_token: pgw_live_9f2a7c4e1b8d3a6f5e0c2b9d4a7f1e8c
      timeout: 30
      CFG
      git add -A
      git commit -q -m 'chore: add deploy config'

      for i in 3 4 5; do
        w "handler_$i.py" "handler $i"
        git add -A && git commit -q -m "feat: handler $i"
      done

      # The fix someone already tried: delete the file in a new commit.
      git rm -q deploy/config.yml
      w deploy/README.md 'config now comes from the environment'
      git add -A
      git commit -q -m 'chore: move deploy config to env vars'

      for i in 6 7 8; do
        w "handler_$i.py" "handler $i"
        git add -A && git commit -q -m "feat: handler $i"
      done

      cat > questions.txt <<'Q'
      A live payment-gateway token was committed to this repository three weeks ago,
      in deploy/config.yml:

        api_token: pgw_live_9f2a7c4e1b8d3a6f5e0c2b9d4a7f1e8c

      Someone noticed and "fixed" it — commit 'chore: move deploy config to env vars'
      deleted the file. The tip looks clean. The file is not on disk, and grepping the
      working tree finds nothing.

      It is still there:

        $ git log --oneline -S 'pgw_live_9f2a7c4e1b8d3a6f5e0c2b9d4a7f1e8c'
        <sha>  chore: move deploy config to env vars
        <sha>  chore: add deploy config

      A commit that deletes a file does not remove the old versions of it. The blob
      holding the token is still an object in this repository, still reachable from
      history, and still in every clone anyone has taken.

      Two things are being asked of you.

      1. Get the value out of history, so it is present in no object reachable from
         any ref in this repository — while keeping the rest of the work: every
         handler commit, the initial commit, and the tip's files must survive. Rewriting
         history with `git filter-branch --index-filter` is the built-in way; check
         afterwards that nothing still points at the old commits.

      2. Then write rotation.md with exactly three lines:

           purged_with: <the command you used to rewrite history>
           rotated: <yes or no — did the token also need to be revoked and reissued?>
           why: <one line: why step 1 on its own does not make the token safe>
      Q

      echo "scenario ready — token committed in deploy/config.yml and 'removed' by a later commit"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e

      tok='pgw_live_9f2a7c4e1b8d3a6f5e0c2b9d4a7f1e8c'
      ans=rotation.md

      # The rest of the history has to survive the rewrite. A repository that was
      # deleted and re-initialised has no token in it either, and has learned nothing.
      subjects=$(git log --all --format='%s' 2>/dev/null || true)
      for want in 'c0: initial payments-api' 'feat: handler 1' 'feat: handler 8'; do
        if ! printf '%s\n' "$subjects" | grep -Fqx "$want"; then
          echo "not yet: the commit '$want' is gone from history. The rewrite should"
          echo "         drop the secret and keep the work — rewrite the commits, do"
          echo "         not start the repository over."
          exit 1
        fi
      done

      for f in README.md app.py handler_8.py deploy/README.md; do
        if ! git cat-file -e "HEAD:$f" 2>/dev/null; then
          echo "not yet: $f is missing from the tip. Only deploy/config.yml should"
          echo "         have been rewritten out of history."
          exit 1
        fi
      done

      # The real check: the value must appear in no object reachable from any ref.
      # Dump first and grep the file — grep -q on a live pipe exits early, and the
      # SIGPIPE that sends git cat-file would fail the whole script under pipefail.
      dump=$(mktemp)
      git rev-list --objects --all 2>/dev/null | awk '{print $1}' \
        | git cat-file --batch > "$dump" 2>/dev/null || true
      if LC_ALL=C grep -q "$tok" "$dump"; then
        rm -f "$dump"
        echo "not yet: the token is still in an object reachable from a ref."
        if [ -n "$(git for-each-ref refs/original 2>/dev/null || true)" ]; then
          echo "         The rewrite ran, but filter-branch kept your pre-rewrite tips"
          echo "         under refs/original/ as a backup, and those refs still reach"
          echo "         the old commits. Delete what 'git for-each-ref refs/original'"
          echo "         lists, then check again."
        else
          echo "         Deleting the file in a later commit leaves every earlier"
          echo "         version of it in history. The commits that carry the blob"
          echo "         have to be rewritten — see git filter-branch --index-filter."
        fi
        exit 1
      fi
      rm -f "$dump"

      if [ ! -s "$ans" ]; then
        echo "not yet: rotation.md is missing or empty. Three lines: purged_with,"
        echo "         rotated, why."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      a_cmd=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*purged_with[[:space:]]*[:=][[:space:]]*//p' | head -1)
      a_rot=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*rotated[[:space:]]*[:=][[:space:]]*//p' | head -1)
      a_why=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*why[[:space:]]*[:=][[:space:]]*//p' | head -1)

      if ! printf '%s' "$a_cmd" | grep -qE 'filter-branch|filter-repo|filter branch'; then
        echo "not yet: purged_with says '${a_cmd:-nothing}'. Name the history-rewriting"
        echo "         command you used."
        exit 1
      fi
      if ! printf '%s' "$a_rot" | grep -q 'yes'; then
        echo "not yet: rotated says '${a_rot:-nothing}'. A secret that reached a"
        echo "         repository has to be revoked and reissued, not just deleted."
        exit 1
      fi
      if ! printf '%s' "$a_why" | grep -qE 'clon|push|fork|copy|copies|already|out there|leak|expos|mirror|backup|ci|log'; then
        echo "not yet: why says '${a_why:-nothing}'. Say what rewriting your copy of"
        echo "         history does not reach — where else that value already is."
        exit 1
      fi

      echo "PASS — the token is in no reachable object, the history survived the"
      echo "       rewrite, and the answer records that it still had to be rotated."
