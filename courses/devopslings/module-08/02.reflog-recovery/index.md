---
kind: lesson
title: "reset --hard on the wrong branch, and the commits that are not really gone"
description: |
  Someone ran git reset --hard on main thinking they were on another branch, and
  three commits — two features and a v2.0 release — vanished from it. The files
  are off disk and git log shows only the base commit. But reset --hard moves a
  pointer, it does not delete commits: the reflog still holds them, and pointing
  the branch back is one command.
name: reflog-recovery
slug: reflog-recovery
createdAt: "2026-08-27"

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

      # Initialise a git repository
      git init -q .
      git config user.email dev@example.com
      git config user.name 'Dev'

      # Create the base commit and name the branch main
      echo 'the project' > README.md
      echo 'shipped: v1.0' > VERSION
      git add -A
      git commit -q -m 'c0: base, shipped v1.0'
      git branch -M main

      # Add three commits of real work
      echo 'feature a' > feature-a.txt
      git add -A
      git commit -q -m 'feat: add feature a'

      echo 'feature b' > feature-b.txt
      git add -A
      git commit -q -m 'feat: add feature b'

      echo 'shipped: v2.0' > VERSION
      echo 'released 2.0' > SHIPPED
      git add -A
      git commit -q -m 'release: ship v2.0'

      # The accident - reset main back to base commit
      base=$(git rev-list --max-parents=0 main)
      git reset --hard "$base" >/dev/null

      # Write questions.txt with the required content
      cat > questions.txt <<'Q'
      main just lost three commits. Someone ran `git reset --hard` on it thinking they
      were on another branch, and it jumped back to the base commit:

        $ git log --oneline
        <base>  c0: base, shipped v1.0

        $ cat VERSION
        shipped: v1.0

      The two features and the v2.0 release are gone from the branch. VERSION is back
      to v1.0, feature-a.txt and feature-b.txt are not on disk. `git log` shows
      nothing but the base commit.

      They are not actually gone. `reset --hard` moved the branch pointer; it did not
      delete the commits. Git keeps a log of every position HEAD has held — the
      reflog — and the lost commits are still in it, still whole:

        $ git reflog
        <sha> HEAD@{1}: commit: release: ship v2.0
        <sha> HEAD@{2}: commit: feat: add feature b
        ...

      Bring main back to the release commit so the work is reachable again — VERSION
      at v2.0, both feature files restored. Point the branch back at the lost tip:

        $ git reset --hard <the sha of the release commit from the reflog>

      Then write recovery.md with exactly two lines:

        recovered_version: <what VERSION should say once the work is back>
        found_with: <the git log of former HEAD positions you used to find the lost commit>
      Q

      echo "scenario ready — main reset --hard back to base, three commits lost from the branch"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      set -e

      ans=recovery.md
      want='shipped: v2.0'

      # The recovered work has to be real: committed and reachable from HEAD, not
      # a file typed back by hand. Read it from the committed tree, not the disk.
      got=$(git cat-file -p HEAD:VERSION 2>/dev/null || true)
      if [ "$got" != "$want" ]; then
        echo "not yet: HEAD still has VERSION as '${got:-missing}', not '$want'."
        echo "         main is not back at the release commit. The lost tip is in"
        echo "         'git reflog'; point the branch at it with git reset --hard."
        exit 1
      fi

      # The whole release, not just the version bump: the two feature files and
      # the shipped marker have to be back in the committed tree too.
      for f in feature-a.txt feature-b.txt SHIPPED; do
        if ! git cat-file -e "HEAD:$f" 2>/dev/null; then
          echo "not yet: $f is not in the recovered commit. Bring main all the way"
          echo "         back to the release commit, not partway."
          exit 1
        fi
      done

      # A clean tree — the recovery is a committed state, not staged or dirty.
      # -uno: ignore untracked files (questions.txt, recovery.md are the lesson's
      # own, not repo content) and check only that tracked files are clean.
      if [ -n "$(git status --porcelain -uno 2>/dev/null)" ]; then
        echo "not yet: tracked files have uncommitted changes. The recovered work"
        echo "         should be the committed state of main, reached with reset."
        exit 1
      fi

      if [ ! -s "$ans" ]; then
        echo "not yet: recovery.md is missing or empty."
        echo "         Two lines: recovered_version and found_with."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      a_ver=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*recovered_version[[:space:]]*[:=][[:space:]]*//p' | head -1)
      a_how=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*found_with[[:space:]]*[:=][[:space:]]*//p' | head -1)

      if ! printf '%s' "$a_ver" | grep -q 'v2.0'; then
        echo "not yet: recovered_version says '${a_ver:-nothing}'. Once the work is"
        echo "         back, VERSION reads 'shipped: v2.0'."
        exit 1
      fi
      if ! printf '%s' "$a_how" | grep -q 'reflog'; then
        echo "not yet: found_with says '${a_how:-nothing}'. Name the log of former"
        echo "         HEAD positions that still held the lost commit."
        exit 1
      fi

      echo "PASS — main is back at the v2.0 release: both features and the version"
      echo "       bump are reachable again, recovered from the reflog."
