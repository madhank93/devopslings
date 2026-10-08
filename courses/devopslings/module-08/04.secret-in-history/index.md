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

      # A local stand-in for the gateway's token API. It, its store, and the brief
      # (which quotes the token) stay out of `git add -A`, as a real issuer would.
      printf '%s\n' gateway .gateway/ questions.txt >> .git/info/exclude
      cat > gateway <<'GW'
      #!/bin/sh
      # Token API for pay.example.com: a token authenticates while its line is "active".
      set -e
      db="$(dirname "$0")/.gateway/tokens"
      case "$1" in
        issue)
          t="pgw_live_$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
          echo "active $t" >> "$db"
          echo "$t" ;;
        revoke)
          if [ -z "$2" ] || ! grep -qx "active $2" "$db"; then
            echo "no active token '$2'" >&2; exit 1
          fi
          sed "s/^active $2\$/revoked $2/" "$db" > "$db.tmp" && mv "$db.tmp" "$db"
          echo "revoked" ;;
        auth)
          if [ -n "$2" ] && grep -qx "active $2" "$db"; then echo "200 ok"
          else echo "401 unauthorized" >&2; exit 1; fi ;;
        list)
          awk '{print $1, substr($2, 1, 14) "..."}' "$db" ;;
        *)
          echo "usage: ./gateway issue | revoke <token> | auth <token> | list" >&2
          exit 2 ;;
      esac
      GW
      chmod +x gateway
      mkdir .gateway
      echo 'active pgw_live_9f2a7c4e1b8d3a6f5e0c2b9d4a7f1e8c' > .gateway/tokens

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
      w deploy/README.md 'config now comes from the environment: GATEWAY_TOKEN, set in deploy/.env (not committed)'
      w .gitignore 'deploy/.env'
      git add -A
      git commit -q -m 'chore: move deploy config to env vars'

      for i in 6 7 8; do
        w "handler_$i.py" "handler $i"
        git add -A && git commit -q -m "feat: handler $i"
      done

      # The value moved to the environment unchanged, which is how it usually goes.
      echo 'GATEWAY_TOKEN=pgw_live_9f2a7c4e1b8d3a6f5e0c2b9d4a7f1e8c' > deploy/.env

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

      The deploy reads its token from deploy/.env (gitignored). The gateway's token
      API is ./gateway:

        ./gateway issue            print a new token
        ./gateway revoke <token>   stop a token authenticating
        ./gateway auth <token>     200 ok, or 401
        ./gateway list

      Close the incident:

      1. Get the value out of history, so it is present in no object reachable from
         any ref in this repository — while keeping the rest of the work: every
         handler commit, the initial commit, and the tip's files must survive. Rewriting
         history with `git filter-branch --index-filter` is the built-in way; check
         afterwards that nothing still points at the old commits.

      2. Leave nothing that anyone holding a copy of that value can use, with the
         deploy still able to authenticate.

      3. Write rotation.md with two lines:

           purged_with: <the command you used to rewrite history>
           why: <one line: why step 1 alone would not have closed the incident>
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
      trap 'rm -f "$dump"' EXIT
      git rev-list --objects --all 2>/dev/null | awk '{print $1}' \
        | git cat-file --batch > "$dump" 2>/dev/null || true
      if LC_ALL=C grep -q "$tok" "$dump"; then
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

      # Rotation is graded at the issuer. The store is read directly rather than
      # through ./gateway, so editing the CLI cannot change the answer.
      db=.gateway/tokens
      live() { [ -n "$1" ] && [ -f "$db" ] && grep -qx "active $1" "$db"; }
      cur=''
      if [ -f deploy/.env ]; then
        cur=$(sed -n 's/^[[:space:]]*GATEWAY_TOKEN[[:space:]]*=[[:space:]]*//p' deploy/.env \
          | head -1 | tr -d "\"' \r")
      fi
      if [ -z "$cur" ]; then
        echo "not yet: deploy/.env sets no GATEWAY_TOKEN, so the deploy cannot"
        echo "         authenticate. It should hold the token the gateway accepts."
        exit 1
      fi
      if [ "$cur" = "$tok" ]; then
        if live "$tok"; then
          echo "not yet: deploy/.env still holds the leaked value, and the gateway"
          echo "         still accepts it. The history is clean, but every copy made"
          echo "         before the rewrite still carries a working credential."
        else
          echo "not yet: the leaked value no longer authenticates, but deploy/.env"
          echo "         still holds it, so the deploy is now locked out too. Point it"
          echo "         at a token the gateway currently accepts."
        fi
        exit 1
      fi
      if ! live "$cur"; then
        echo "not yet: deploy/.env holds a token the gateway does not accept"
        echo "         ('./gateway auth' returns 401 for it). Use one it issued and"
        echo "         has not revoked."
        exit 1
      fi
      if live "$tok"; then
        echo "not yet: the deploy uses a new token, but the leaked one still"
        echo "         authenticates. Issuing a replacement does not retire the old"
        echo "         value — anyone holding it can still use it until it is revoked."
        exit 1
      fi
      if LC_ALL=C grep -q "$cur" "$dump"; then
        echo "not yet: the new token is in an object reachable from a ref — it has"
        echo "         been committed, which leaks it the same way. Keep it in the"
        echo "         untracked deploy/.env and rewrite it out of history."
        exit 1
      fi

      if [ ! -s "$ans" ]; then
        echo "not yet: rotation.md is missing or empty. Two lines: purged_with, why."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      a_cmd=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*purged_with[[:space:]]*[:=][[:space:]]*//p' | head -1)
      a_why=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*why[[:space:]]*[:=][[:space:]]*//p' | head -1)

      if ! printf '%s' "$a_cmd" | grep -qE 'filter-branch|filter-repo|filter branch'; then
        echo "not yet: purged_with says '${a_cmd:-nothing}'. Name the history-rewriting"
        echo "         command you used."
        exit 1
      fi
      if ! printf '%s' "$a_why" | grep -qE 'clon|push|fork|copy|copies|already|out there|leak|expos|mirror|backup|\bci\b|log|pull'; then
        echo "not yet: why says '${a_why:-nothing}'. Say what rewriting your copy of"
        echo "         history does not reach — where else that value already is."
        exit 1
      fi

      echo "PASS — the leaked token is in no reachable object and no longer"
      echo "       authenticates, the history survived the rewrite, and the deploy"
      echo "       runs on an uncommitted replacement."
