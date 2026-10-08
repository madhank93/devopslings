---
kind: lesson
title: "the NOPASSWD line that reads like log access and spends like a root shell"
description: |
  deploybot has two passwordless sudo grants: restart one service, and run awk.
  The second is not a smaller privilege than the first — it is every privilege,
  because awk runs a program you hand it, and under sudo that program runs as
  root. Closing it is not about constraining awk's arguments; it is about
  granting the access that was actually needed.
name: nopasswd-shell-escape
slug: nopasswd-shell-escape
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

      # 1. Idempotent teardown
      rm -f /etc/sudoers.d/deploybot /etc/systemd/system/app.service /var/log/app.log /root/answers/sudo.md
      systemctl daemon-reload 2>/dev/null || true
      userdel -r deploybot 2>/dev/null || true
      groupdel logreaders 2>/dev/null || true

      # 2. Create the account and a group that does not include it yet
      useradd -m -s /bin/bash deploybot
      groupadd logreaders
      install -d /root/answers

      # 3. Create a systemd unit
      cat > /etc/systemd/system/app.service <<'UNIT'
      [Unit]
      Description=the app deploybot restarts

      [Service]
      Type=oneshot
      RemainAfterExit=yes
      ExecStart=/bin/true
      UNIT
      systemctl daemon-reload

      # 4. Create the log file
      echo "app started" > /var/log/app.log
      chown root:root /var/log/app.log
      chmod 0600 /var/log/app.log

      # 5. Write the sudoers drop-in
      cat > /etc/sudoers.d/deploybot <<'SUDO'
      deploybot ALL=(root) NOPASSWD: /usr/bin/awk
      deploybot ALL=(root) NOPASSWD: /usr/bin/systemctl restart app.service
      SUDO
      chmod 0440 /etc/sudoers.d/deploybot
      visudo -cf /etc/sudoers.d/deploybot

      # 6. Write questions file
      cat > /root/questions.txt <<'Q'
      deploybot has two NOPASSWD sudo grants:

        $ sudo -u deploybot sudo -n -l

      One of them is meant to let it restart app.service. The other is meant to let
      it run log reports with awk. A security review marked this drop-in critical:
      between them, these grants let deploybot become root.

      Show the escalation, then close it. deploybot has three things that must hold
      afterwards:
        - it can still restart app.service with sudo, no password
        - it can still read /var/log/app.log
        - it can NOT run anything else as root

      Then write /root/answers/sudo.md with exactly two lines:

        dangerous_binary: <name>
        mechanism: <one or two words for why that binary can never be a safe
                    NOPASSWD grant>
      Q

      # 7. End message
      echo "scenario ready — deploybot's sudo drop-in, flagged critical"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e

      ans=/root/answers/sudo.md

      # deploybot's escalation attempt, asked directly. -n means "never prompt":
      # if awk is no longer a NOPASSWD grant the call fails fast instead of
      # hanging on a password. Running id changes no state, so this is safe to
      # repeat.
      esc=$(sudo -u deploybot sudo -n /usr/bin/awk 'BEGIN{system("id")}' 2>/dev/null || true)
      if printf '%s' "$esc" | grep -q 'uid=0'; then
        echo "not yet: deploybot still becomes root with one command:"
        echo "         sudo -n awk 'BEGIN{system(\"id\")}'  ->  $esc"
        echo "         sudo still runs awk as root for deploybot without a password,"
        echo "         and awk runs any program it is handed. Whichever grant still"
        echo "         matches awk — the awk line or a broader one — is the hole."
        exit 1
      fi

      # The two things deploybot must keep. Restart first: it is the grant that
      # is supposed to survive. Stop the unit as root beforehand, so "active"
      # afterwards can only mean deploybot's own restart worked — not that the
      # service happened to be up already.
      systemctl stop app.service >/dev/null 2>&1 || true
      sudo -u deploybot sudo -n /usr/bin/systemctl restart app.service >/dev/null 2>&1 || true
      if [ "$(systemctl is-active app.service 2>/dev/null)" != "active" ]; then
        echo "not yet: deploybot can no longer restart app.service without a"
        echo "         password. That grant is legitimate and has to stay:"
        echo "         deploybot ALL=(root) NOPASSWD: /usr/bin/systemctl restart app.service"
        exit 1
      fi

      if ! sudo -u deploybot test -r /var/log/app.log; then
        echo "not yet: deploybot can no longer read /var/log/app.log."
        echo "         Reading a log does not need root — give deploybot the"
        echo "         access through group membership, not through sudo."
        exit 1
      fi

      # Nothing else may be reachable as root. Every command sudo grants
      # deploybot must be the pinned restart; a denylist of shell-escape
      # binaries would miss bash, an unpinned systemctl, ALL, and the rest.
      extra=$(sudo -u deploybot sudo -n -l 2>/dev/null \
        | sed -n '/may run the following commands/,$p' | sed 1d \
        | sed -E 's/^[[:space:]]*\([^)]*\)[[:space:]]*//; s/([A-Z_]+:[[:space:]]*)+//' \
        | tr ',' '\n' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' \
        | grep -vxE '(/usr)?/bin/systemctl restart app(\.service)?|' || true)
      if [ -n "$extra" ]; then
        echo "not yet: deploybot can still run more than the pinned restart as root:"
        printf '%s\n' "$extra" | sed 's/^/         /'
        echo "         The only grant deploybot needs is"
        echo "         /usr/bin/systemctl restart app.service. Anything else it can run"
        echo "         as root is a way to run everything as root."
        exit 1
      fi

      # The name and the reason.
      if [ ! -s "$ans" ]; then
        echo "not yet: /root/answers/sudo.md is missing or empty."
        echo "         Two lines: dangerous_binary and mechanism."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      binname=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*dangerous_binary[[:space:]]*[:=][[:space:]]*\([a-z0-9_-]*\).*/\1/p' | head -1)
      mech=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*mechanism[[:space:]]*[:=][[:space:]]*//p' | head -1)

      if [ "$binname" != "awk" ]; then
        echo "not yet: dangerous_binary says '${binname:-nothing}'."
        echo "         The planted grant was for the one binary in the two lines"
        echo "         that runs a program you supply."
        exit 1
      fi
      if ! printf '%s' "$mech" | grep -qE '\b(arbitrary|shells?|system|commands?|exec[a-z]*|programs?|programming|interpreter|gtfobins)\b'; then
        echo "not yet: mechanism says '${mech:-nothing}'."
        echo "         Name what awk does that a pager or a pinned systemctl does"
        echo "         not: it runs an arbitrary command of the caller's choosing."
        exit 1
      fi

      echo "PASS — the awk grant is gone, deploybot keeps its restart and its log,"
      echo "       and no remaining grant is a shell in disguise."
