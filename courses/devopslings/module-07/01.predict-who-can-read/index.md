---
kind: lesson
title: "who can read this file, and why the group bits did not save you"
description: |
  Seven files, two users, and one question asked seven times: can this account
  read that path. Every answer is decidable from the permission bits without
  running a thing, and two of them come out the opposite way from how they
  read, because the kernel checks one permission class rather than the most
  generous one.
name: predict-who-can-read
slug: predict-who-can-read
createdAt: "2026-08-24"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      set -e

      # Idempotent teardown
      rm -rf /srv/app /var/backups/dump.sql /root/answers/access.md
      userdel -r dana 2>/dev/null || true
      userdel -r sam 2>/dev/null || true
      groupdel deploy 2>/dev/null || true

      # Create the accounts
      groupadd deploy
      useradd -m -s /bin/bash -G deploy dana
      useradd -m -s /bin/bash sam
      install -d /root/answers

      # Create directories with exact owners and modes
      install -d -o root -g root -m 0755 /srv/app
      install -d -o root -g root -m 0755 /srv/app/public
      install -d -o root -g root -m 0700 /srv/app/secrets
      install -d -o root -g deploy -m 0750 /srv/app/data

      # Create files with content, then set ownership and permissions
      echo "classified" > /srv/app/config.yml
      chown root:deploy /srv/app/config.yml
      chmod 0640 /srv/app/config.yml

      echo "classified" > /srv/app/notes.txt
      chown dana:deploy /srv/app/notes.txt
      chmod 0040 /srv/app/notes.txt

      echo "classified" > /srv/app/public/readme.txt
      chown root:root /srv/app/public/readme.txt
      chmod 0644 /srv/app/public/readme.txt

      echo "classified" > /srv/app/secrets/token
      chown root:root /srv/app/secrets/token
      chmod 0644 /srv/app/secrets/token

      echo "classified" > /srv/app/data/report.csv
      chown dana:deploy /srv/app/data/report.csv
      chmod 0004 /srv/app/data/report.csv

      echo "classified" > /var/backups/dump.sql
      chown root:root /var/backups/dump.sql
      chmod 0600 /var/backups/dump.sql

      # Create symlink
      ln -s /srv/app/secrets/token /srv/app/latest-token

      # Write questions file
      cat > /root/questions.txt <<'Q'
      Seven questions. Answer them by reading the permissions, not by running the
      reads — the point of the exercise is to be right before you touch anything.

        ls -l /srv/app /srv/app/public /srv/app/secrets /srv/app/data
        id dana
        id sam

        case1  can dana read /srv/app/config.yml
        case2  can sam  read /srv/app/config.yml
        case3  can dana read /srv/app/notes.txt
        case4  can sam  read /srv/app/public/readme.txt
        case5  can dana read /srv/app/secrets/token
        case6  can dana read /srv/app/latest-token
        case7  can dana read /srv/app/data/report.csv

      Write /root/answers/access.md with exactly eight lines:

        case1: yes
        case2: no
        ...
        case7: yes
        decided_by: <owner|group|other>

      decided_by names which of the three permission classes decided case3 — the
      class the kernel actually used, not the one you would have wanted it to use.
      Q

      echo "scenario ready — seven files, two users, no reads yet"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e

      ans=/root/answers/access.md
      if [ ! -s "$ans" ]; then
        echo "not yet: /root/answers/access.md is missing or empty."
        echo "         Seven case lines and a decided_by line — see /root/questions.txt."
        exit 1
      fi

      # Ground truth is whatever the kernel does, asked one case at a time.
      # Nothing here changes state, so the check can run as often as it likes.
      truth() {
        if sudo -u "$1" cat "$2" >/dev/null 2>&1; then echo yes; else echo no; fi
      }

      low=$(tr 'A-Z' 'a-z' < "$ans")
      said() {
        printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*\\([a-z]*\\).*/\\1/p" | head -1
      }

      users="dana sam dana sam dana dana dana"
      paths="/srv/app/config.yml /srv/app/config.yml /srv/app/notes.txt /srv/app/public/readme.txt /srv/app/secrets/token /srv/app/latest-token /srv/app/data/report.csv"

      wrong=0
      missing=0
      i=0
      for p in $paths; do
        i=$((i + 1))
        u=$(echo $users | cut -d' ' -f$i)
        got=$(said "case$i")
        want=$(truth "$u" "$p")

        if [ -z "$got" ]; then
          echo "not yet: case$i has no answer in $ans."
          missing=1
          continue
        fi
        if [ "$got" != "yes" ] && [ "$got" != "no" ]; then
          echo "not yet: case$i says '$got'. Each case line is yes or no."
          missing=1
          continue
        fi
        if [ "$got" != "$want" ]; then
          wrong=$((wrong + 1))
          echo "not yet: case$i — you said $got, and $u reading $p does not do that."
          case $i in
            3|7)
              echo "         Look again at who owns the file and which class dana"
              echo "         falls into. The kernel checks one class, not the best one."
              ;;
            5|6)
              echo "         Reaching a file means walking every directory above it."
              echo "         Check each component of the path, not just the last."
              ;;
            *)
              echo "         id $u, then the file's owner, group and mode."
              ;;
          esac
        fi
      done

      [ "$missing" -eq 0 ] || exit 1

      if [ "$wrong" -ne 0 ]; then
        echo ""
        echo "         $wrong of 7 are wrong. The bits have not changed since you"
        echo "         answered — the prediction is what is being graded."
        exit 1
      fi

      decided=$(said decided_by)
      if [ "$decided" != "owner" ]; then
        echo "not yet: decided_by says '${decided:-nothing}'."
        echo "         case3 is a file dana owns, in a group dana belongs to,"
        echo "         where the group bits would have allowed the read. It was"
        echo "         refused anyway. Name the class that got there first."
        exit 1
      fi

      echo "PASS — seven predictions, all correct, and the rule that decides the"
      echo "       awkward ones named."
