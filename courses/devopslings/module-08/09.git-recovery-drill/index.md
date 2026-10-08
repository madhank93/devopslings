---
kind: lesson
title: "the release check fails, and the cause is somewhere in the history"
description: |
  The release check fails on a fresh clone of main. That is the whole ticket,
  every time — because the fault is drawn at random from five, each a different
  way git loses or leaks work: commits reset away, a regression deep in history,
  a merge that kept one side, a submodule pinned backwards, a token in an old
  commit. The drill is the order you ask the repository questions in.
name: git-recovery-drill
slug: git-recovery-drill
createdAt: "2026-09-29"

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
      root=$(pwd)

      h() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | awk '{print $1}'; }

      mkdir -p remotes .drill .issuer
      git init -q --bare remotes/fmt.git
      git init -q --bare remotes/app.git
      git -C remotes/fmt.git symbolic-ref HEAD refs/heads/main
      git -C remotes/app.git symbolic-ref HEAD refs/heads/main

      # ---- the vendored formatter: two commits, the second adds the separator
      tmp=$(mktemp -d)
      git init -q "$tmp/fmt"
      git -C "$tmp/fmt" config user.email dev@example.com
      git -C "$tmp/fmt" config user.name 'Dev'
      cat > "$tmp/fmt/fmt.sh" <<'F'
      # fmt_money <cents>: the amount as the receipt prints it.
      fmt_money() {
        printf '%d.%02d\n' $(( $1 / 100 )) $(( $1 % 100 ))
      }
      F
      git -C "$tmp/fmt" add -A
      git -C "$tmp/fmt" commit -q -m 'fmt_money: cents as a decimal'
      git -C "$tmp/fmt" branch -M main
      cat > "$tmp/fmt/fmt.sh" <<'F'
      # fmt_money <cents>: the amount as the receipt prints it.
      fmt_money() {
        u=$(( $1 / 100 )); out=""
        while [ "$u" -ge 1000 ]; do
          out=$(printf ',%03d%s' $(( u % 1000 )) "$out")
          u=$(( u / 1000 ))
        done
        printf '%d%s.%02d\n' "$u" "$out" $(( $1 % 100 ))
      }
      F
      git -C "$tmp/fmt" commit -q -am 'fmt_money: thousands separator'
      fmt_old=$(git -C "$tmp/fmt" rev-parse main~1)
      fmt_new=$(git -C "$tmp/fmt" rev-parse main)
      git -C "$tmp/fmt" push -q "$root/remotes/fmt.git" main
      rm -rf "$tmp"

      # ---- the draw -----------------------------------------------------
      #
      # One fault per run, woven into the history as it is built. Only a digest
      # of it is kept, beside a digest of the one commit the grader needs for it.
      faults="reflog bisect merge submodule secret"
      n=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
      fault=$(echo "$faults" | cut -d' ' -f$(( n % 5 + 1 )))

      token="pgw_live_$(od -An -tx1 -N12 /dev/urandom | tr -d ' \n')"
      echo "active $token" > .issuer/tokens
      cat > issuer <<'GW'
      #!/bin/sh
      # The payment gateway's token API: a token authenticates while its line is "active".
      set -e
      db="$(dirname "$0")/.issuer/tokens"
      case "$1" in
        revoke)
          if [ -z "$2" ] || ! grep -qx "active $2" "$db"; then
            echo "no active token '$2'" >&2; exit 1
          fi
          sed "s/^active $2\$/revoked $2/" "$db" > "$db.tmp" && mv "$db.tmp" "$db"
          echo revoked ;;
        list)
          awk '{print $1, substr($2, 1, 14) "..."}' "$db" ;;
        *)
          echo "usage: ./issuer revoke <token> | list" >&2; exit 2 ;;
      esac
      GW
      chmod +x issuer

      # ---- the application ----------------------------------------------
      git init -q app
      cd app
      git config user.email dev@example.com
      git config user.name 'Dev'
      git remote add origin "$root/remotes/app.git"

      tax_round=half; cap=no; ship=flat
      write_lib() {
        {
          echo '. ./vendor/fmt/fmt.sh'
          echo
          if [ "$tax_round" = half ]; then
            echo '# Tax is 8%, rounded half up, in cents.'
            echo 'tax() { echo $(( ($1 * 8 + 50) / 100 )); }'
          else
            echo '# Tax is 8%, in cents.'
            echo 'tax() { echo $(( $1 * 8 / 100 )); }'
          fi
          echo
          echo '# Percentage off, in cents.'
          echo 'discount() {'
          echo '  pct=$2'
          [ "$cap" = yes ] && echo '  if [ "$pct" -gt 30 ]; then pct=30; fi'
          echo '  echo $(( $1 - $1 * pct / 100 ))'
          echo '}'
          echo
          echo '# Shipping, in cents.'
          echo 'shipping() {'
          if [ "$ship" = free ]; then
            echo '  if [ "$1" -ge 50000 ]; then echo 0; else echo 1500; fi'
          else
            echo '  echo 1500'
          fi
          echo '}'
          echo
          echo '# checkout <subtotal cents> <coupon %>: what the customer is charged.'
          echo 'checkout() {'
          echo '  p=$(discount "$1" "$2")'
          echo '  fmt_money $(( p + $(tax "$p") + $(shipping "$p") ))'
          echo '}'
        } > lib.sh
      }

      i=0
      commit() { i=$((i + 1)); git add -A; git commit -q -m "$1"; }
      filler() { mkdir -p handlers; echo "handler $((i + 1))" > "handlers/h$((i + 1)).sh"; commit "feat: handler $((i + 1))"; }

      write_lib
      printf 'shop: checkout, tax and coupons\n' > README.md
      echo 2.3 > VERSION
      git -c protocol.file.allow=always submodule add -q ../fmt.git vendor/fmt
      git -C vendor/fmt checkout -q "$fmt_old"
      commit 'app: checkout, tax and coupons'
      git branch -M main
      filler
      mkdir -p docs
      cat > docs/example.env <<'E'
      # Copy to deploy/.env for a local run. The value is the gateway's documented
      # test-mode placeholder; it authenticates nowhere.
      PAY_TOKEN=pgw_test_0000000000000000000000000
      E
      commit 'docs: example env for local runs'
      filler; filler
      git -C vendor/fmt checkout -q "$fmt_new"
      commit 'vendor/fmt: thousands separator'
      filler; filler; filler

      git checkout -q -b hotfix/coupon-cap
      cap=yes; write_lib
      git commit -q -am 'fix: cap coupons at 30%'
      hotfix=$(git rev-parse HEAD)
      git checkout -q main
      cap=no
      filler; filler
      if [ "$fault" = merge ]; then
        # Recorded as merged, contributes nothing: the hotfix is an ancestor of
        # main and its change is not in main's tree.
        git merge -q --no-ff -s ours -m "Merge branch 'hotfix/coupon-cap'" hotfix/coupon-cap
        key=$hotfix
      else
        git merge -q --no-ff -m "Merge branch 'hotfix/coupon-cap'" hotfix/coupon-cap
        cap=yes
      fi
      i=$((i + 1))
      filler

      if [ "$fault" = secret ]; then
        mkdir -p deploy
        printf 'PAY_URL=https://pay.example.com\nPAY_TOKEN=%s\n' "$token" > deploy/prod.env
        commit 'chore: deploy env for staging'
        key=$(git rev-parse HEAD)
      else
        filler
      fi
      filler
      if [ "$fault" = secret ]; then
        git rm -q deploy/prod.env
        echo 'deploy/*.env' > .gitignore
        commit 'chore: deploy reads the token from the environment'
      else
        filler
      fi
      filler
      if [ "$fault" = bisect ]; then
        tax_round=trunc; write_lib
        commit 'lib: simplify tax arithmetic'
        key=$(git rev-parse HEAD)
      else
        filler
      fi
      filler
      if [ "$fault" = submodule ]; then
        # A commit -a from a working copy whose submodule was never updated.
        git -C vendor/fmt checkout -q "$fmt_old"
        echo 'vendored: fmt' > VENDORED
        commit 'chore: refresh vendored libs'
        key=$(git rev-parse HEAD)
      else
        filler
      fi
      while [ "$i" -lt 27 ]; do filler; done

      ship=free; write_lib
      commit 'feat: free shipping from 500.00'
      echo 'Shipping is free from 500.00 after discount.' >> README.md
      commit 'docs: shipping threshold'
      echo 2.4 > VERSION
      commit 'release: v2.4'

      git push -q origin main hotfix/coupon-cap
      git branch -q -u origin/main main 2>/dev/null || true
      if [ "$fault" = reflog ]; then
        key=$(git rev-parse HEAD)
        git reset -q --hard HEAD~3
        git push -q --force origin main
      fi
      cd "$root"

      { printf '%s' "$fault" | h; printf '%s' "$fault:$key" | h; } > .drill/state
      chmod 600 .drill/state

      cat > release-check.sh <<'RC'
      #!/bin/sh
      # What CI runs before a release: a fresh recursive clone of origin, the
      # receipt total for the reference cart, and a scan of every branch's history.
      root=$(cd "$(dirname "$0")" && pwd)
      w=$(mktemp -d); trap 'rm -rf "$w"' EXIT
      git -c protocol.file.allow=always clone -q --recurse-submodules \
        "$root/remotes/app.git" "$w/app" || { echo "release check: FAIL (clone)"; exit 1; }
      cd "$w/app" || exit 1
      fail=0
      got=$(sh -c '. ./lib.sh; checkout 200010 50' 2>&1)
      if [ "$got" = "1,512.08" ]; then echo "ok    reference cart: $got"
      else echo "FAIL  reference cart: expected 1,512.08, got '$got'"; fail=1; fi
      hits=$(git log -p --all | grep -cE 'pgw_live_[0-9a-f]{8,}')
      if [ "$hits" -eq 0 ]; then echo "ok    history scan"
      else echo "FAIL  history scan: $hits line(s) match a live gateway token"; fail=1; fi
      [ "$fail" -eq 0 ] && echo "release check: PASS" && exit 0
      echo "release check: FAIL"; exit 1
      RC
      chmod +x release-check.sh

      cat > questions.txt <<'Q'
      The release check fails on main, and v2.4 cannot ship:

        sh release-check.sh

      It clones remotes/app.git the way CI does, prints the receipt total for the
      reference cart (it should be 1,512.08), and scans the history of every
      branch for a live gateway token. It passed on every release before this one.

      Exactly one thing went wrong in this repository's history — drawn at random
      from five, each a different way git loses, breaks or leaks work.

        app/            your working copy of the application (origin: remotes/app.git)
        app/vendor/fmt  a submodule; its origin is remotes/fmt.git
        ./issuer        the payment gateway's token API: revoke <token> | list

      remotes/ is what CI and the grader read, so a repair is not done until it
      is pushed. Clone with `git -c protocol.file.allow=always ...` — the origins
      are directories on this machine, and that flag is all it takes.

      Two things to do.

      1. Make the release check pass by repairing what went wrong, at its cause.
         Editing release-check.sh changes nothing: the grader runs its own.

      2. Write triage.md, three lines:

           cause:     <what happened, in a few words>
           evidence:  <the command that proved it>
           detection: <a signal and a threshold that would have caught it first>

      Ask the repository in order: is everything main should have still on it,
      what does it record for the submodule, did every merge bring its side,
      where did behaviour change, and what is in the history that should not be.
      Run the lesson again and the fault moves.
      Q

      echo "scenario ready — one fault seeded, release check failing"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      h() { if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | awk '{print $1}'; }

      digest=$(sed -n 1p .drill/state 2>/dev/null || true)
      marker=$(sed -n 2p .drill/state 2>/dev/null || true)
      fault=""
      for cand in reflog bisect merge submodule secret; do
        [ "$(printf '%s' "$cand" | h)" = "$digest" ] && fault=$cand
      done
      if [ -z "$fault" ]; then
        echo "not yet: .drill/state does not name a seeded fault. Start the lesson"
        echo "         again — the scenario has to seed one before it can be graded."
        exit 1
      fi
      if [ ! -d remotes/app.git ] || [ ! -d remotes/fmt.git ]; then
        echo "not yet: remotes/app.git or remotes/fmt.git is missing. They are what"
        echo "         CI clones; the repair has to be pushed to them, not replace them."
        exit 1
      fi

      root=$(pwd)
      w=$(mktemp -d)
      trap 'rm -rf "$w"' EXIT

      # ---- the symptom: the grader's own release check -------------------
      if ! git -c protocol.file.allow=always clone -q --recurse-submodules \
           "$root/remotes/app.git" "$w/app" 2>"$w/err"; then
        echo "not yet: a fresh recursive clone of remotes/app.git fails:"
        sed 's/^/         /' "$w/err"
        exit 1
      fi
      unit() { (cd "$w/app" && sh -c ". ./lib.sh; $1" 2>&1) || true; }
      got=$(unit 'checkout 200010 50')
      git -C "$w/app" log -p --all > "$w/log" 2>/dev/null || true
      hits=$(grep -cE 'pgw_live_[0-9a-f]{8,}' "$w/log" || true)
      if [ "$got" != "1,512.08" ] || [ "$hits" -ne 0 ]; then
        echo "not yet: the release check still fails on a fresh clone of remotes/app.git."
        [ "$got" != "1,512.08" ] && echo "         The reference cart prints '$got'; the release total is 1,512.08."
        [ "$hits" -ne 0 ] && echo "         $hits line(s) in the history of its branches match a live gateway token."
        echo "         Ask the repository in order: git reflog (is everything main had"
        echo "         still on it), git submodule status and git log -- vendor/fmt,"
        echo "         git log --merges with git show, git bisect for a behaviour that"
        echo "         changed, git log -p -S for what should never have been committed."
        exit 1
      fi

      # ---- the repair is at the cause, not around it ----------------------
      subjects=$(git -C remotes/app.git log main --format=%s 2>/dev/null || true)
      for s in 'app: checkout, tax and coupons' 'vendor/fmt: thousands separator' \
               "Merge branch 'hotfix/coupon-cap'" 'feat: handler 25' \
               'feat: free shipping from 500.00' 'release: v2.4'; do
        if ! printf '%s\n' "$subjects" | grep -Fqx "$s"; then
          echo "not yet: origin main has no commit '$s', and that work was on main"
          echo "         when the ticket came in. The release total is right, and main"
          echo "         has lost history on the way: a repair moves main forward or"
          echo "         rewrites only what must go, it does not start main over or"
          echo "         reset it to an older branch."
          exit 1
        fi
      done

      # The total can be made right in checkout() alone; each rule has to be
      # right where it lives.
      for pair in 'tax 1019=82' 'discount 10000 50=7000' 'shipping 60000=0'; do
        call=${pair%=*}; want=${pair#*=}
        g=$(unit "$call")
        if [ "$g" != "$want" ]; then
          echo "not yet: the reference cart totals right, and '$call' prints '$g'"
          echo "         where it should print $want. The total was corrected around a"
          echo "         rule that is still wrong; repair the rule where it lives."
          exit 1
        fi
      done

      entry=$(git -C "$w/app" ls-tree HEAD vendor/fmt)
      mode=$(printf '%s' "$entry" | awk '{print $1}')
      rec=$(printf '%s' "$entry" | awk '{print $3}')
      fmt_fix=$(git -C remotes/fmt.git log main --format=%H --grep='thousands separator' | awk 'NR==1')
      if [ "$mode" != 160000 ]; then
        echo "not yet: vendor/fmt is no longer a submodule on origin main (tree entry"
        echo "         mode ${mode:-absent}, not 160000). Copying the formatter's files in"
        echo "         builds today and cuts the link to its history."
        exit 1
      fi
      if ! git -C remotes/fmt.git merge-base --is-ancestor "$rec" main 2>/dev/null; then
        echo "not yet: origin main records vendor/fmt at $(printf '%s' "$rec" | cut -c1-7),"
        echo "         which is not on remotes/fmt.git's main. A gitlink has to name a"
        echo "         commit the submodule's own origin publishes."
        exit 1
      fi
      if ! git -C remotes/fmt.git merge-base --is-ancestor "$fmt_fix" "$rec"; then
        echo "not yet: the total is right, and origin main still records vendor/fmt at"
        echo "         $(printf '%s' "$rec" | cut -c1-7), before 'thousands separator'."
        echo "         Something other than the pinned library is supplying the"
        echo "         separator; move the gitlink to the published fix."
        exit 1
      fi

      tok=$(awk 'NR==1{print $2}' .issuer/tokens 2>/dev/null || true)
      git -C remotes/app.git rev-list --objects --all 2>/dev/null | awk '{print $1}' \
        | git -C remotes/app.git cat-file --batch > "$w/dump" 2>/dev/null || true
      if [ -n "$tok" ] && LC_ALL=C grep -q "$tok" "$w/dump"; then
        echo "not yet: a ref in remotes/app.git (a tag, or a branch the scan does not"
        echo "         clone) still reaches an object holding the live token. Every ref"
        echo "         has to be rewritten or deleted, not only main."
        exit 1
      fi

      if [ "$fault" = reflog ]; then
        found=""
        for c in $(git -C remotes/app.git rev-list main); do
          [ "$(printf '%s' "reflog:$c" | h)" = "$marker" ] && found=yes && break
        done
        if [ -z "$found" ]; then
          echo "not yet: the seeded fault was a reset --hard and a force push that took"
          echo "         the last three commits off main. origin main has their content"
          echo "         back as new commits; the originals still exist in app's reflog"
          echo "         with their own hashes, and main should point at them."
          exit 1
        fi
      fi
      if [ "$fault" = secret ] && grep -qx "active $tok" .issuer/tokens; then
        echo "not yet: the token is out of history, and ./issuer list shows it still"
        echo "         active. It was pushed, so every clone taken before the rewrite"
        echo "         holds a working credential. Revoke it."
        exit 1
      fi

      # ---- the red herring ----------------------------------------------
      want_env=$(printf '%s\n' \
        '# Copy to deploy/.env for a local run. The value is the gateway'"'"'s documented' \
        '# test-mode placeholder; it authenticates nowhere.' \
        'PAY_TOKEN=pgw_test_0000000000000000000000000')
      have_env=$(git -C remotes/app.git show main:docs/example.env 2>/dev/null || true)
      if [ "$have_env" != "$want_env" ]; then
        if [ -z "$have_env" ]; then
          echo "not yet: docs/example.env is gone from origin main."
        else
          echo "not yet: docs/example.env on origin main has changed."
        fi
        echo "         Its pgw_test_ value is the gateway's documented placeholder and"
        echo "         authenticates nowhere; the scan matches pgw_live_ only. It was"
        echo "         never part of the fault — put it back as it was."
        exit 1
      fi

      # ---- naming it ------------------------------------------------------
      if [ ! -s triage.md ]; then
        echo "not yet: triage.md is missing or empty. Three lines: cause, evidence,"
        echo "         detection."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < triage.md)
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | awk 'NR==1'; }
      a_cause=$(field cause); a_ev=$(field evidence); a_det=$(field detection)

      case "$fault" in
        reflog)
          what="a reset --hard on main, force-pushed, that dropped the last three commits"
          c_re='\b(reset|force|forced|lost|reflog|rewound|dropped)\b'
          e_re='\breflog\b|\blog -g\b'
          e_say="the reflog, which still held the lost tip"
          d_re='\b(force|forced|non-fast-forward|denynonfastforwards|protected|protection)\b'
          d_say="force pushes to main (a rejected non-fast-forward, branch protection)" ;;
        bisect)
          what="a regression: 'lib: simplify tax arithmetic' changed tax rounding"
          c_re='\b(regression|regressed|bisect|introduced|rounding|tax)\b'
          e_re='\bbisect\b'
          e_say="git bisect, which named the commit"
          d_re='\b(ci|test|tests|pipeline|per[- ]commit|every commit|pre-merge)\b'
          d_say="a test run on every commit (CI, pre-merge)" ;;
        merge)
          what="the hotfix/coupon-cap merge was resolved with only main's side, dropping the cap"
          c_re='\bmerg(e|ed|ing)\b'
          e_re='\b(show|diff|merges|first-parent|cherry|log)\b'
          e_say="git show or git diff of the merge against its second parent"
          d_re='\b(test|tests|ci|diff|review|merges?)\b'
          d_say="a test for the hotfix, or a check of what each merge brought in"
          ;;
        submodule)
          what="'chore: refresh vendored libs' moved the vendor/fmt gitlink back to an older commit"
          c_re='\b(submodule|gitlink|pinned|pin|pointer|vendor/fmt)\b'
          e_re='\b(submodule|ls-tree|gitlink|diff)\b'
          e_say="git submodule status, git ls-tree or git log -p -- vendor/fmt"
          d_re='\b(submodule|gitlink|clone|ci)\b'
          d_say="a CI check on a fresh recursive clone, or on gitlinks that move backwards"
          ;;
        secret)
          what="a live gateway token committed in deploy/prod.env and deleted in a later commit"
          c_re='\b(secret|token|credential|leak|leaked|key)\b'
          e_re='\b(grep|scan|scanner|pickaxe|rev-list|cat-file)\b|(^|[[:space:]])-[sg]\b|log -p'
          e_say="git log -p -S <value>, or a scan of every object"
          d_re='\b(scan|scanner|scanning|hook|pre-commit|pre-receive|gitleaks|trufflehog|push protection)\b'
          d_say="a secret scan in a pre-commit or pre-receive hook"
          ;;
      esac

      fail=0
      if [ -z "$a_cause" ] || ! printf '%s' "$a_cause" | grep -Eq "$c_re"; then
        fail=1
        echo "not yet: cause says '${a_cause:-nothing}', and the release check passes, so"
        echo "         something was repaired. What was seeded:"
        echo "         $what."
      fi
      if [ "$fault" = bisect ] && [ "$fail" -eq 0 ]; then
        bad=""
        for c in $(git -C remotes/app.git rev-list main); do
          [ "$(printf '%s' "bisect:$c" | h)" = "$marker" ] && bad=$c && break
        done
        named=""
        for s in $(printf '%s\n' "$low" | grep -oE '\b[0-9a-f]{7,40}\b' || true); do
          case "$bad" in "$s"*) named=yes ;; esac
        done
        if [ -z "$named" ]; then
          fail=1
          echo "not yet: triage.md does not name the commit that broke tax rounding."
          echo "         A regression's cause is a commit: put its sha (7+ characters) in"
          echo "         the cause line."
        fi
      fi
      if [ -z "$a_ev" ] || ! printf '%s' "$a_ev" | grep -Eq "$e_re"; then
        fail=1
        echo "not yet: evidence says '${a_ev:-nothing}'. For this fault the proof is"
        echo "         $e_say."
      fi
      if [ -z "$a_det" ] || ! printf '%s' "$a_det" | grep -Eq "$d_re"; then
        fail=1
        echo "not yet: detection says '${a_det:-nothing}'. Name a signal that would have"
        echo "         caught this before the release check: $d_say."
      elif ! printf '%s' "$a_det" | grep -q '[0-9]'; then
        fail=1
        echo "not yet: detection names a signal and no threshold. Say at what number"
        echo "         it pages — '> 0 force pushes', 'any failing test', with the number."
      fi
      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the seeded fault ($fault) was repaired at its cause, origin main"
      echo "       kept its history and its example env, and triage.md names it."
---
