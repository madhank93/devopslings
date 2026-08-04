---
kind: lesson
title: "three positional arguments and nobody remembers the order"
description: |
  rotate-logs takes a directory, a number of days and a compress flag, in that
  order, and getting it wrong deletes the wrong things quietly. Give it named
  flags, a default, a usage message, and a refusal to run when it has not been
  told what it needs.
name: arguments-and-usage
slug: arguments-and-usage
createdAt: "2026-08-04"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      install -d /srv/logs /var/lib/devopslings /root/answers

      cat > /usr/local/bin/make-logs <<'SH'
      #!/bin/bash
      # Rebuilds a predictable log directory: 4 old files, 3 recent ones.
      set -euo pipefail
      target=${1:-/srv/logs}
      rm -rf "$target"
      mkdir -p "$target"
      for i in 1 2 3 4; do
        printf 'old log %d\n' "$i" > "$target/app-old-$i.log"
        touch -d '30 days ago' "$target/app-old-$i.log"
      done
      for i in 1 2 3; do
        printf 'recent log %d\n' "$i" > "$target/app-new-$i.log"
      done
      SH
      chmod 0755 /usr/local/bin/make-logs

      cat > /usr/local/bin/rotate-logs <<'SH'
      #!/bin/bash
      # rotate-logs <dir> <days> <compress>
      #
      # Nobody can remember whether days or dir comes first, there is no way to
      # ask, and getting it wrong does something destructive without complaint.
      set -euo pipefail
      dir=$1
      days=$2
      compress=$3

      mkdir -p "$dir/archive"
      find "$dir" -maxdepth 1 -type f -name '*.log' -mtime +"$days" -print0 \
        | while IFS= read -r -d '' f; do
            mv -- "$f" "$dir/archive/"
            [ "$compress" = "yes" ] && gzip -f -- "$dir/archive/$(basename -- "$f")"
          done
      SH
      chmod 0755 /usr/local/bin/rotate-logs

      /usr/local/bin/make-logs /srv/logs

      cat > /root/questions.txt <<'Q'
      Rewrite /usr/local/bin/rotate-logs to take named flags instead of three
      positional arguments. It must:

        --dir <path>     required. If missing, print a message naming it to
                         stderr and exit non-zero.
        --days <n>       optional, default 7.
        --compress       optional flag, off by default. When given, gzip the
                         files it archives.
        -h | --help      print a usage message listing the flags, exit 0.

      An unknown flag must be rejected: message to stderr, non-zero exit.

      Keep the behaviour: files older than --days move from <dir> into
      <dir>/archive, newer files are left alone.
      Q

      echo "scenario ready — rotate-logs takes <dir> <days> <compress> positionally"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      bin=/usr/local/bin/rotate-logs
      if [ ! -x "$bin" ]; then
        echo "not yet: $bin is missing or not executable"
        exit 1
      fi

      # 1. Help.
      set +e
      help_out=$("$bin" --help 2>&1); help_rc=$?
      set -e
      if [ "$help_rc" -ne 0 ]; then
        echo "not yet: --help exited $help_rc; it should print usage and exit 0"
        exit 1
      fi
      for flag in -- --dir --days --compress; do
        case "$flag" in --) continue ;; esac
        if ! printf '%s' "$help_out" | grep -q -- "$flag"; then
          echo "not yet: the --help output does not mention $flag"
          printf '%s\n' "$help_out" | head -8 | sed 's/^/         /'
          exit 1
        fi
      done

      set +e
      h2=$("$bin" -h 2>&1); h2rc=$?
      set -e
      if [ "$h2rc" -ne 0 ]; then
        echo "not yet: -h exited $h2rc; it should behave like --help"
        exit 1
      fi

      # 2. Missing required argument.
      set +e
      miss_out=$("$bin" 2>&1 >/dev/null); miss_rc=$?
      set -e
      if [ "$miss_rc" -eq 0 ]; then
        echo "not yet: running with no arguments exited 0"
        echo "         --dir is required; with nothing to work on it must refuse."
        exit 1
      fi
      if ! printf '%s' "$miss_out" | grep -qi 'dir'; then
        echo "not yet: it exited $miss_rc but the message on stderr does not name --dir"
        echo "         '$miss_out'"
        echo "         the person who ran it has to be told WHICH argument is missing."
        exit 1
      fi

      # 3. Unknown flag.
      set +e
      unk_out=$("$bin" --dir /srv/logs --purge-everything 2>&1 >/dev/null); unk_rc=$?
      set -e
      if [ "$unk_rc" -eq 0 ]; then
        echo "not yet: an unknown flag (--purge-everything) was accepted silently"
        echo "         a typo'd flag must never be ignored — that is how a script ends up"
        echo "         running with a default nobody intended."
        exit 1
      fi

      # 4. The default for --days.
      /usr/local/bin/make-logs /srv/logs
      set +e
      "$bin" --dir /srv/logs >/dev/null 2>&1; rc=$?
      set -e
      if [ "$rc" -ne 0 ]; then
        echo "not yet: '--dir /srv/logs' with no --days exited $rc; --days should default to 7"
        exit 1
      fi
      arch=$(find /srv/logs/archive -maxdepth 1 -type f 2>/dev/null | wc -l)
      left=$(find /srv/logs -maxdepth 1 -type f -name '*.log' 2>/dev/null | wc -l)
      if [ "$arch" -ne 4 ] || [ "$left" -ne 3 ]; then
        echo "not yet: with the default, expected 4 archived and 3 left; got $arch and $left"
        exit 1
      fi
      if find /srv/logs/archive -name '*.gz' | grep -q .; then
        echo "not yet: files were compressed without --compress being given"
        exit 1
      fi

      # 5. Explicit --days and --compress.
      /usr/local/bin/make-logs /srv/logs
      set +e
      "$bin" --dir /srv/logs --days 1 --compress >/dev/null 2>&1; rc=$?
      set -e
      if [ "$rc" -ne 0 ]; then
        echo "not yet: '--dir /srv/logs --days 1 --compress' exited $rc"
        exit 1
      fi
      gz=$(find /srv/logs/archive -maxdepth 1 -name '*.gz' 2>/dev/null | wc -l)
      left=$(find /srv/logs -maxdepth 1 -type f -name '*.log' 2>/dev/null | wc -l)
      if [ "$gz" -ne 4 ] || [ "$left" -ne 3 ]; then
        echo "not yet: with --days 1 --compress, expected 4 .gz archived and 3 left;"
        echo "         got $gz and $left"
        exit 1
      fi

      echo "PASS — named flags, --days defaults to 7, --compress is off unless asked,"
      echo "       --help works, and a missing or unknown flag is refused by name."
---
