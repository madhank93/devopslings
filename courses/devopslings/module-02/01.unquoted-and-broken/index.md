---
kind: lesson
title: "the archive script that ate the quarterly report"
description: |
  archive-inbox has worked every night for a year. Last night someone saved a
  file with a space in the name, and this morning there are two files in the
  archive that never existed and one that is gone. Filenames are not words.
name: unquoted-and-broken
slug: unquoted-and-broken
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      install -d /srv/inbox /srv/archive /root/answers /var/lib/devopslings

      # The fixture generator, used by init and re-used by the check so every
      # run starts from exactly the same five awkward names.
      cat > /usr/local/bin/make-inbox <<'SH'
      #!/bin/bash
      set -euo pipefail
      rm -rf /srv/inbox /srv/archive
      mkdir -p /srv/inbox /srv/archive
      cd /srv/inbox
      printf 'ordinary\n'          > 'orders.csv'
      printf 'has a space\n'       > 'quarterly report.csv'
      printf 'leading dash\n'      > '-rf.txt'
      printf 'literal asterisk\n'  > '*.csv'
      printf 'newline in name\n'   > "$(printf 'two\nlines.txt')"
      SH
      chmod 0755 /usr/local/bin/make-inbox

      # The script as it has been for a year. It works, right up until a
      # filename contains a character the shell treats as syntax.
      cat > /usr/local/bin/archive-inbox <<'SH'
      #!/bin/bash
      # Move everything in the inbox to the archive.
      for f in $(ls /srv/inbox); do
        mv /srv/inbox/$f /srv/archive/
      done
      SH
      chmod 0755 /usr/local/bin/archive-inbox

      /usr/local/bin/make-inbox

      # Record the five names and their contents as the ground truth.
      ( cd /srv/inbox && find . -maxdepth 1 -type f -print0 \
          | sort -z \
          | xargs -0 -I{} sh -c 'printf "%s\0" "{}"; cat "{}"' ) \
        | sha256sum | awk '{print $1}' > /var/lib/devopslings/inbox.sha256
      find /srv/inbox -maxdepth 1 -type f | wc -l > /var/lib/devopslings/inbox.count

      cat > /root/questions.txt <<'Q'
      /usr/local/bin/archive-inbox moves everything from /srv/inbox to
      /srv/archive. Run it once and look at what happens.

      Fix it so that EVERY file arrives in /srv/archive with its name and
      contents intact, whatever the name contains — spaces, newlines, a leading
      dash, or a literal asterisk.

      The check rebuilds the inbox from scratch, runs YOUR /usr/local/bin/archive-inbox,
      and then compares the archive against the original names and contents.
      Q

      echo "scenario ready — /srv/inbox has five files and archive-inbox mishandles four of them"
      ls -1b /srv/inbox

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      if [ ! -x /usr/local/bin/archive-inbox ]; then
        echo "not yet: /usr/local/bin/archive-inbox is missing or not executable"
        exit 1
      fi

      want_sha=$(cat /var/lib/devopslings/inbox.sha256)
      want_n=$(cat /var/lib/devopslings/inbox.count)

      # Rebuild the inbox so the run is from a known state every time.
      /usr/local/bin/make-inbox

      if ! /usr/local/bin/archive-inbox; then
        echo "not yet: archive-inbox exited non-zero"
        exit 1
      fi

      left=$(find /srv/inbox -maxdepth 1 -type f 2>/dev/null | wc -l)
      got_n=$(find /srv/archive -maxdepth 1 -type f 2>/dev/null | wc -l)

      if [ "$got_n" -ne "$want_n" ]; then
        echo "not yet: expected $want_n files in /srv/archive and found $got_n"
        echo "         what is actually there:"
        find /srv/archive -maxdepth 1 -type f -printf '           %f\n' 2>/dev/null | head -10
        if [ "$left" -gt 0 ]; then
          echo "         and still in /srv/inbox:"
          find /srv/inbox -maxdepth 1 -type f -printf '           %f\n' 2>/dev/null | head -10
        fi
        exit 1
      fi

      got_sha=$( ( cd /srv/archive && find . -maxdepth 1 -type f -print0 \
          | sort -z \
          | xargs -0 -I{} sh -c 'printf "%s\0" "{}"; cat "{}"' ) \
        | sha256sum | awk '{print $1}' )

      if [ "$got_sha" != "$want_sha" ]; then
        echo "not yet: the right number of files arrived, but the names or contents differ"
        echo "         in the archive:"
        find /srv/archive -maxdepth 1 -type f -printf '           %f\n' 2>/dev/null | head -10
        echo "         a file whose name was split into two words arrives as two files,"
        echo "         or as one file with the wrong name."
        exit 1
      fi

      if [ "$left" -ne 0 ]; then
        echo "not yet: $left file(s) are still in /srv/inbox"
        exit 1
      fi

      echo "PASS — all $want_n files archived with names and contents intact,"
      echo "       including the ones containing a space, a newline, a leading dash"
      echo "       and a literal asterisk."
---
