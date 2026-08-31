---
kind: lesson
title: "your fix is checked out, and CI keeps building the commit before it"
description: |
  The vendored library is a submodule, the fix is published upstream, and your
  own build has passed all week — because your working copy holds the fixed
  library. A clone reads the commit the parent records, not the directory you
  are standing in. The grader clones the application's origin the way CI does,
  and requires that clone to build the fix with vendor/liblog still a submodule.
name: submodule-detached
slug: submodule-detached
createdAt: "2026-08-31"

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

      mkdir -p remotes
      git init -q --bare remotes/liblog.git
      git init -q --bare remotes/app.git
      # A bare repo's HEAD still names the default branch of whoever created it; point
      # both at main so a clone lands on the branch that actually has commits.
      git -C remotes/liblog.git symbolic-ref HEAD refs/heads/main
      git -C remotes/app.git symbolic-ref HEAD refs/heads/main

      tmp=$(mktemp -d)
      root=$(pwd)

      # Build library history
      git init -q "$tmp/liblog"
      git -C "$tmp/liblog" config user.email dev@example.com
      git -C "$tmp/liblog" config user.name 'Dev'

      cat >"$tmp/liblog/liblog.sh" <<'F'
      # liblog — format one event as one line.
      log_line() {
        # $1 level, $2 message
        printf '%s\n' "$2"
      }
      F

      git -C "$tmp/liblog" add liblog.sh
      git -C "$tmp/liblog" commit -q -m 'log_line: one line per event'
      git -C "$tmp/liblog" branch -M main

      cat >"$tmp/liblog/liblog.sh" <<'F'
      # liblog — format one event as one line.
      log_line() {
        # $1 level, $2 message
        printf '%s: %s\n' "$1" "$2"
      }
      F

      git -C "$tmp/liblog" add liblog.sh
      git -C "$tmp/liblog" commit -q -m 'log_line: include the level in the line'

      buggy=$(git -C "$tmp/liblog" rev-parse main~1)

      git -C "$tmp/liblog" remote add origin "$root/remotes/liblog.git"
      git -C "$tmp/liblog" push -q origin main

      # Build application history
      git init -q "$tmp/app"
      git -C "$tmp/app" config user.email dev@example.com
      git -C "$tmp/app" config user.name 'Dev'
      # The submodule url in .gitmodules is relative, so it resolves against the
      # superproject's origin — which has to exist before the submodule is added.
      git -C "$tmp/app" remote add origin "$root/remotes/app.git"

      cat >"$tmp/app/run.sh" <<'F'
      . ./vendor/liblog/liblog.sh
      log_line ERROR "checkout failed: gateway timeout"
      F

      cat >"$tmp/app/test.sh" <<'F'
      # The build asserts the log line carries its severity.
      out=$(sh run.sh)
      if [ "$out" = "ERROR: checkout failed: gateway timeout" ]; then
        echo "ok: $out"
        exit 0
      fi
      echo "FAIL: expected 'ERROR: checkout failed: gateway timeout', got '$out'"
      exit 1
      F

      # protocol.file.allow gates git's *own* clones over a local path, so it has to
      # be passed on the command line: a repository-local setting is not read by the
      # clone that submodule add spawns.
      git -C "$tmp/app" -c protocol.file.allow=always submodule add -q ../liblog.git vendor/liblog
      git -C "$tmp/app/vendor/liblog" checkout -q "$buggy"
      git -C "$tmp/app" add vendor/liblog
      git -C "$tmp/app" add -A
      git -C "$tmp/app" commit -q -m 'app: vendor liblog'
      git -C "$tmp/app" branch -M main
      git -C "$tmp/app" push -q origin main

      # Create learner's working copy
      git -c protocol.file.allow=always clone -q --recurse-submodules "$root/remotes/app.git" app
      git -C app config user.email dev@example.com
      git -C app config user.name 'Dev'

      # Someone has already pulled inside the submodule, so the working copy holds
      # the fixed library while the parent still records the old commit
      git -C app/vendor/liblog fetch -q origin main
      git -C app/vendor/liblog checkout -q FETCH_HEAD

      rm -rf "$tmp"
      cat > questions.txt <<'Q'
      The application logs one line per event through a vendored library, and for a
      week every line on CI has arrived without its severity — "checkout failed:
      gateway timeout" where it should read "ERROR: checkout failed: gateway timeout".

      The library is a submodule at vendor/liblog, with its own origin. The fix is
      already published there, and it is already checked out in your working copy, so
      your own build passes:

          cd app && sh test.sh

      CI does not build your working copy. It clones the application from its origin
      and takes the library from what that clone records:

          git -c protocol.file.allow=always clone --recurse-submodules \
              remotes/app.git /tmp/ci
          cd /tmp/ci && sh test.sh

      Run those two commands and watch the severity disappear again. The -c flag is
      only needed because these origins are directories on this machine rather than a
      server; nothing else in the exercise depends on it.

      Make that clone build the fixed library. remotes/ holds both origins and is what
      the grader reads. vendor/liblog must still be a submodule when you are done —
      copying the library's files into the application would pass a build and lose the
      link to the library's history.
      Q

      echo "scenario ready — app/ with vendor/liblog, and remotes/ holding both origins"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      set -e

      if [ ! -d remotes/app.git ] || [ ! -d app ]; then
        echo "not yet: remotes/app.git or app/ is missing. The grader clones the"
        echo "         application from remotes/app.git, the way CI does."
        exit 1
      fi

      root=$(pwd)
      work=$(mktemp -d)
      fix=$(git -C remotes/liblog.git rev-parse main)
      buggy=$(git -C remotes/liblog.git rev-parse main~1)
      fix_s=$(git -C remotes/liblog.git rev-parse --short main)
      buggy_s=$(git -C remotes/liblog.git rev-parse --short main~1)

      # What the pushed history records, before anything is checked out.
      if ! git clone -q "$root/remotes/app.git" "$work/parent" 2>"$work/err"; then
        echo "not yet: remotes/app.git no longer clones:"
        sed 's/^/         /' "$work/err"
        exit 1
      fi

      entry=$(git -C "$work/parent" ls-tree HEAD vendor/liblog)
      mode=$(printf '%s' "$entry" | awk '{print $1}')
      recorded=$(printf '%s' "$entry" | awk '{print $3}')
      rec_s=$(printf '%s' "$recorded" | cut -c1-7)

      if [ "$mode" != 160000 ]; then
        echo "not yet: in the pushed history vendor/liblog is no longer a submodule"
        echo "         (its tree entry is mode ${mode:-absent}, not 160000). Copying the"
        echo "         library's files into this repository does make CI build them, and"
        echo "         it also ends the link to the library's own history: the next fix"
        echo "         upstream is a manual copy again. Record the commit instead."
        exit 1
      fi

      # A gitlink names a commit; nothing checks that the commit is fetchable until
      # someone clones, which is exactly what CI does.
      if ! git -C remotes/liblog.git cat-file -e "$recorded^{commit}" 2>/dev/null; then
        echo "not yet: the parent records submodule commit $rec_s, which"
        echo "         remotes/liblog.git does not have. A gitlink is a"
        echo "         promise that the commit can be fetched from the submodule's own"
        echo "         origin; a commit that exists only in your vendor/liblog directory"
        echo "         cannot be. Push the library first, then the application."
        exit 1
      fi

      if ! git -C remotes/liblog.git merge-base --is-ancestor "$recorded" main; then
        echo "not yet: the recorded commit $rec_s is in remotes/liblog.git but is not on"
        echo "         its main. Point the submodule at the published fix on main,"
        echo "         not at a commit off to the side."
        exit 1
      fi

      # The clone CI makes: recursive, from the origin, with nothing of the learner's
      # working tree in it.
      if ! git -c protocol.file.allow=always clone -q --recurse-submodules \
           "$root/remotes/app.git" "$work/ci" 2>"$work/err"; then
        echo "not yet: a fresh recursive clone of remotes/app.git failed:"
        sed 's/^/         /' "$work/err"
        exit 1
      fi

      out=$(cd "$work/ci" && sh test.sh 2>&1) && ok=yes || ok=no

      if [ "$ok" != yes ]; then
        local_rec=$(git -C app ls-tree HEAD vendor/liblog | awk '{print $3}')
        sub_head=$(git -C app/vendor/liblog rev-parse HEAD 2>/dev/null || echo none)

        if [ "$local_rec" = "$fix" ] && [ "$recorded" = "$buggy" ]; then
          echo "not yet: your app/ commit records the fixed library, and the clone of"
          echo "         remotes/app.git still records $buggy_s. That commit is local; CI"
          echo "         clones the origin, so the parent has to be pushed too:"
          echo "         git push origin main."
          exit 1
        fi
        if [ "$recorded" = "$buggy" ] && [ "$sub_head" = "$fix" ]; then
          echo "not yet: vendor/liblog is checked out at the fix — your own test.sh passes"
          echo "         — and the parent still records $buggy_s. Moving the submodule's"
          echo "         HEAD changes a working directory; what a clone reads is the"
          echo "         commit recorded in the parent. git add vendor/liblog stages"
          echo "         that pointer; then commit and push the parent."
          exit 1
        fi
        if [ "$sub_head" != "$fix" ] && [ "$recorded" != "$fix" ]; then
          echo "not yet: neither the submodule's HEAD nor the recorded commit is the"
          echo "         library's published fix $fix_s. Inside vendor/liblog:"
          echo "         git fetch origin main, then check out that commit."
          exit 1
        fi
        echo "not yet: the fresh clone builds the library at $rec_s and its test"
        echo "         still fails:"
        printf '%s\n' "$out" | sed 's/^/         /'
        exit 1
      fi

      echo "PASS — remotes/app.git records liblog $rec_s as a submodule, that"
      echo "       commit is on the library's own main, and a clone that has never seen"
      echo "       your working tree builds and passes."
