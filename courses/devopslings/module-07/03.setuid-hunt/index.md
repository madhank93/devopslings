---
kind: lesson
title: "the setuid hunt, where the dangerous binary and sudo look identical"
description: |
  Two setuid-root binaries were planted on the box, each a one-command root
  shell. Finding them is easy; the trap is the fix. Nine setuid binaries on this
  box are supposed to be there — sudo among them — and the blunt instrument that
  strips the planted ones strips sudo too, leaving you unable to become root at
  all. The signal that separates them is not the mode; it is package ownership.
name: setuid-hunt
slug: setuid-hunt
createdAt: "2026-08-25"

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
      rm -f /usr/local/bin/maint /opt/tools/backup /root/answers/setuid.md
      rmdir /opt/tools 2>/dev/null || true
      userdel -r probe 2>/dev/null || true

      # Create an unprivileged account and the answers dir
      useradd -m -s /bin/bash probe
      install -d /root/answers

      # Plant the first rogue: a setuid-root copy of bash in /usr/local/bin
      cp /bin/bash /usr/local/bin/maint
      chown root:root /usr/local/bin/maint
      chmod 4755 /usr/local/bin/maint

      # Plant the second rogue: a setuid-root copy of dash in /opt/tools
      install -d /opt/tools
      cp /bin/dash /opt/tools/backup
      chown root:root /opt/tools/backup
      chmod 4755 /opt/tools/backup

      # Write questions file
      cat > /root/questions.txt <<'Q'
      Two setuid-root binaries were planted on this box. Each one is a root shell for
      any user who runs it:

        $ sudo -u probe /usr/local/bin/maint -p -c id
        uid=1000(probe) ... euid=0(root)

      Find every setuid-root binary that does not belong, and neutralise it. The trap
      is that this box also has nine setuid binaries that DO belong — sudo, su,
      passwd, mount, umount, chfn, chsh, gpasswd, newgrp — and stripping any of those
      breaks the system. In particular, `chmod -R` or a blanket
      `find / -perm -4000 -exec chmod u-s {} \;` will disable sudo, and then you
      cannot become root at all.

      The difference is not the mode — a planted setuid binary and sudo look
      identical. It is provenance: every legitimate setuid binary on a Debian box is
      owned by an installed package, and the planted ones are not.

        $ find / -xdev -perm -4000 -type f 2>/dev/null
        $ dpkg -S /usr/bin/sudo          # owned by a package
        $ dpkg -S /usr/local/bin/maint   # no path found -> does not belong

      Neutralise every unpackaged setuid binary (delete it, or strip its setuid bit),
      and leave the nine legitimate ones exactly as they are.

      Then write /root/answers/setuid.md with exactly two lines:

        unpackaged_setuid: <how many you found>
        found_with: <the command that separates legitimate from planted>
      Q

      echo "scenario ready — two planted setuid roots among nine legitimate ones"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e

      ans=/root/answers/setuid.md

      # Every setuid-root binary currently on the box. A legitimate one is owned
      # by an installed package; a planted one is not. This is the whole test —
      # provenance, not mode.
      # System setuid binaries never contain spaces in their paths, so a plain
      # word split over the find output is safe and avoids a heredoc (whose
      # terminator cannot be indented inside this YAML block).
      rogue=""
      for f in $(find / -xdev -perm -4000 -type f 2>/dev/null); do
        dpkg -S "$f" >/dev/null 2>&1 || rogue="$rogue $f"
      done

      if [ -n "$rogue" ]; then
        echo "not yet: a setuid-root binary remains that no package owns:"
        for f in $rogue; do echo "         $f"; done
        echo "         Anything setuid that dpkg does not own was placed by hand."
        echo "         Delete it or strip its setuid bit — it is a root shell for"
        echo "         whoever runs it."
        exit 1
      fi

      # The nine that must survive. Stripping any of these is the failure the
      # lesson is really about: a blanket chmod that also disables sudo.
      for p in sudo su passwd mount umount chfn chsh gpasswd newgrp; do
        path=$(command -v "$p" 2>/dev/null || true)
        if [ -z "$path" ] || [ ! -u "$path" ]; then
          echo "not yet: $p is no longer setuid (${path:-not found})."
          echo "         That is a legitimate, package-owned setuid binary. A"
          echo "         blanket strip catches these too — and without sudo"
          echo "         setuid you can no longer become root at all. Put it back:"
          echo "         chmod u+s ${path:-\$(command -v $p)}"
          exit 1
        fi
      done

      if [ ! -s "$ans" ]; then
        echo "not yet: /root/answers/setuid.md is missing or empty."
        echo "         Two lines: unpackaged_setuid and found_with."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      cnt=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*unpackaged_setuid[[:space:]]*[:=][[:space:]]*\([0-9]*\).*/\1/p' | head -1)
      how=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*found_with[[:space:]]*[:=][[:space:]]*//p' | head -1)

      if [ "$cnt" != "2" ]; then
        echo "not yet: unpackaged_setuid says '${cnt:-nothing}'."
        echo "         Two setuid binaries on this box were owned by no package."
        exit 1
      fi
      if ! printf '%s' "$how" | grep -qE 'dpkg|apt-file|package|debsums'; then
        echo "not yet: found_with says '${how:-nothing}'."
        echo "         Name the command that tells a package-owned binary from one"
        echo "         that was placed by hand — the ownership query, not the"
        echo "         setuid search itself."
        exit 1
      fi

      echo "PASS — both planted setuid roots are gone, every legitimate setuid"
      echo "       binary is intact, and the way to tell them apart is named."
