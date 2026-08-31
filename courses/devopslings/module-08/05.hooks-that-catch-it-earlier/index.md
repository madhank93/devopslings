---
kind: lesson
title: "stop the token at the commit, and know what that is worth"
description: |
  The secret that had to be rewritten out of history should never have been
  committed. A pre-commit hook can refuse it — but a hook that greps your files
  blocks every commit you make, because your own .env holds a real token, and a
  hook that greps for the word "token" blocks the docs. The grader commits six
  times in a copy of your repository and requires the right answer on all six,
  then asks what `--no-verify` does to the whole idea.
name: hooks-that-catch-it-earlier
slug: hooks-that-catch-it-earlier
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

      mkdir -p src docs tests/fixtures

      cat > src/app.py <<'F'
      def charge(amount, token):
          return gateway.post(amount, token)
      F

      # Three things that a careless detector mistakes for a secret.
      cat > docs/configuration.md <<'F'
      # Configuration

      The service reads its gateway credential from the environment:

          api_token: <injected by the deploy, never committed>

      Rotate it with `vault rotate payments/api_token`.
      F

      cat > tests/fixtures/gateway_response.json <<'F'
      {
        "status": "ok",
        "access_token": "test-token-not-a-real-one",
        "expires_in": 3600
      }
      F

      cat > package-lock.json <<'F'
      {
        "name": "payments-api",
        "dependencies": {
          "left-pad": {
            "integrity": "sha512-9f2a7c4e1b8d3a6f5e0c2b9d4a7f1e8c3d6b0a5e2c7f4b1d8e3a6c9f2b5d0e7a"
          }
        }
      }
      F

      printf '.env\n' > .gitignore

      git add -A
      git commit -q -m 'c0: payments-api'
      git branch -M main

      # A developer's own credential, ignored and never committed. A hook that
      # scans the working tree finds this and blocks every commit in the repo.
      printf 'PGW_TOKEN=pgw_live_9f2a7c4e1b8d3a6f5e0c2b9d4a7f1e8c\n' > .env

      cat > questions.txt <<'Q'
      Last month a gateway token reached this repository and had to be rewritten out
      of history, and rotated, because a rewrite does not reach anyone's clone. The
      cheapest place to have stopped it was the commit that introduced it.

      Install a pre-commit hook for this repository that refuses a commit whose
      staged changes add a gateway credential — the shape is pgw_live_ followed by
      32 hex characters — and that lets every other commit through.

      "Every other commit" is the hard half. This repository already contains:

        docs/configuration.md            documents api_token and how to rotate it
        tests/fixtures/gateway_response.json   a fake access_token in test data
        package-lock.json                a 64-character hex integrity hash
        .env                             your own real token, gitignored, untracked

      A hook that greps for the word "token" blocks the docs. A hook that greps for
      a long hex string blocks the lockfile. A hook that scans the files in your
      working directory finds the .env and blocks everything you ever commit,
      including this repository's ordinary changes.

      The grader makes six commits in a copy of this repository: four that must be
      allowed, and two that add a credential — in two different files — and must be
      refused.

      Then write rationale.md with exactly three lines:

        no_verify: <what happens when someone commits with --no-verify>
        shared: <does this hook protect a colleague who clones the repo? why>
        backstop: <where the same check also has to run, given the two answers above>
      Q

      echo "scenario ready — payments-api, with a gitignored .env holding a live token"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      set -e

      ans=rationale.md

      if [ ! -s "$ans" ]; then
        echo "not yet: rationale.md is missing or empty. Three lines: no_verify,"
        echo "         shared, backstop."
        exit 1
      fi

      # Every commit experiment runs in a copy, so the learner's repository is
      # never modified. A copy, not a clone: .git/hooks is not cloned, which is
      # the same reason the hook protects nobody else.
      work=$(mktemp -d)
      cp -a . "$work"/ 2>/dev/null || true
      cd "$work"
      git config user.email dev@example.com
      git config user.name 'Dev'
      base=$(git rev-parse HEAD)

      # try <name> <expect: allow|block> <file> <content-appended>
      # Each case starts from the same commit, so the cases cannot affect
      # each other.
      try() {
        git reset -q --hard "$base"
        mkdir -p "$(dirname "$3")"
        printf '%s\n' "$4" >> "$3"
        git add "$3"
        if git commit -q -m "grader: $1" >/dev/null 2>&1; then
          echo allow
        else
          echo block
        fi
      }

      tok='pgw_live_9f2a7c4e1b8d3a6f5e0c2b9d4a7f1e8c'

      got=$(try 'ordinary source change' allow src/app.py '# a comment')
      if [ "$got" != allow ]; then
        # Three different mistakes refuse this commit, so establish which one
        # rather than guessing: does the hook look at the staged change at all,
        # and does it stop refusing once the local .env is out of the way?
        git reset -q --hard "$base"
        if git commit -q --allow-empty -m 'grader: probe' >/dev/null 2>&1; then
          echo "not yet: the hook refused a comment added to src/app.py. Nothing in that"
          echo "         change is a credential — but the diff around it is not empty:"
          echo "         the context lines of git diff carry the rest of the function,"
          echo "         including the word token. Match the credential's shape, and"
          echo "         match it only on added lines (^\\+)."
          exit 1
        fi
        git reset -q --hard "$base"
        # Out of the repository entirely: a working-tree scan would still find
        # it under any name left inside the directory.
        stash=$(mktemp -d)
        mv .env "$stash"/.env 2>/dev/null || true
        if git commit -q --allow-empty -m 'grader: probe' >/dev/null 2>&1; then
          mv "$stash"/.env .env 2>/dev/null || true
          echo "not yet: the hook refuses every commit while .env is present, and allows"
          echo "         one once it is moved aside. It is scanning the files in the"
          echo "         working directory, so it finds the token in your own gitignored"
          echo "         .env — a file that is never committed. Scan what is staged"
          echo "         instead: git diff --cached."
          exit 1
        fi
        mv "$stash"/.env .env 2>/dev/null || true
        echo "not yet: the hook refuses every commit, including an empty one with the"
        echo "         .env moved out of the way. It is not examining the staged change"
        echo "         at all. A hook that always exits non-zero stops the credential"
        echo "         and everything else with it."
        exit 1
      fi

      got=$(try 'documentation' allow docs/configuration.md 'See also the rotation runbook.')
      if [ "$got" != allow ]; then
        echo "not yet: the hook refused a change to docs/configuration.md. The file"
        echo "         talks about api_token; it does not contain one. Matching the"
        echo "         word rather than the credential makes the hook something people"
        echo "         route around."
        exit 1
      fi

      got=$(try 'test fixture' allow tests/fixtures/gateway_response.json '{"access_token": "another-fake"}')
      if [ "$got" != allow ]; then
        echo "not yet: the hook refused a change to a test fixture whose access_token"
        echo "         is obviously fake. Test data that looks like credentials is"
        echo "         normal, and a hook that cannot tell the difference gets disabled."
        exit 1
      fi

      got=$(try 'lockfile' allow package-lock.json '"integrity": "sha512-0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f9"')
      if [ "$got" != allow ]; then
        echo "not yet: the hook refused a lockfile change. A 64-character hex string"
        echo "         is an integrity hash, not a secret. Match the credential's shape"
        echo "         — pgw_live_ and 32 hex — not 'long and hex'."
        exit 1
      fi

      got=$(try 'the credential' block deploy/config.yml "api_token: $tok")
      if [ "$got" != block ]; then
        echo "not yet: the hook allowed a commit that adds $tok"
        echo "         to deploy/config.yml. That is the commit this whole exercise"
        echo "         exists to refuse."
        exit 1
      fi

      got=$(try 'the credential again, elsewhere' block src/settings.py "TOKEN = \"$tok\"")
      if [ "$got" != block ]; then
        echo "not yet: the hook allowed the same credential in src/settings.py. It"
        echo "         refused it in deploy/config.yml, so the hook is keyed on the"
        echo "         path rather than on the content. A secret is a secret in any"
        echo "         file."
        exit 1
      fi

      # Back to the learner's repository for the written answer.
      cd - >/dev/null
      rm -rf "$work"

      low=$(tr 'A-Z' 'a-z' < "$ans")
      a_nv=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*no_verify[[:space:]]*[:=][[:space:]]*//p' | head -1)
      a_sh=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*shared[[:space:]]*[:=][[:space:]]*//p' | head -1)
      a_bs=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*backstop[[:space:]]*[:=][[:space:]]*//p' | head -1)

      if ! printf '%s' "$a_nv" | grep -qE 'skip|bypass|not run|never run|ignore|disable|nothing|no hook'; then
        echo "not yet: no_verify says '${a_nv:-nothing}'. Say what the flag does to the"
        echo "         hook you just wrote — it is one word, and it is the reason a"
        echo "         hook is a convenience rather than a control."
        exit 1
      fi
      if printf '%s' "$a_sh" | grep -qE '^ *yes'; then
        echo "not yet: shared says '${a_sh}'. .git/hooks is not part of the repository"
        echo "         and is not copied by git clone, so a colleague who clones this"
        echo "         gets no hook at all unless they install one themselves."
        exit 1
      fi
      if ! printf '%s' "$a_sh" | grep -qE 'no|not|clone|local|\.git|install|copied|share'; then
        echo "not yet: shared says '${a_sh:-nothing}'. Answer whether a colleague who"
        echo "         clones this repository is protected by your hook, and say what"
        echo "         about .git/hooks decides that."
        exit 1
      fi
      if ! printf '%s' "$a_bs" | grep -qE 'ci|server|pre-receive|receive|remote|push|scan|pipeline|forge|github|gitlab|review'; then
        echo "not yet: backstop says '${a_bs:-nothing}'. If the hook can be skipped with"
        echo "         a flag and does not travel with a clone, name the place that"
        echo "         checks the same thing where neither is true."
        exit 1
      fi

      echo "PASS — the hook refuses the credential in any file, allows the docs, the"
      echo "       fixture, the lockfile and ordinary work, and the answer says what"
      echo "       --no-verify and an uncloned .git/hooks mean for relying on it."
