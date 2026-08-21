---
kind: lesson
title: "turn off password logins on a box you are sitting inside"
description: |
  Security wants password authentication off. The dangerous part is not the
  setting, it is the order: turn it off before key login works and the next
  person to connect is nobody. There is also a drop-in file that quietly wins
  over the config you are about to edit.
name: ssh-without-locking-yourself-out
slug: ssh-without-locking-yourself-out
createdAt: "2026-08-21"

sandbox:
  stack: netlab
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e

      install -d /root/answers /lab

      # ---- a box that takes passwords ----------------------------------
      ssh-keygen -A >/dev/null 2>&1

      id deploy >/dev/null 2>&1 || useradd -m -s /bin/bash deploy
      echo 'deploy:deploy-2026' | chpasswd
      rm -rf /home/deploy/.ssh

      # Debian's sshd_config pulls in the drop-in directory on its first line,
      # and sshd takes the *first* value it sees for a keyword. That ordering is
      # the trap in this lesson: whatever is in sshd_config.d wins over the file
      # everyone edits.
      cat > /etc/ssh/sshd_config <<'CONF'
      Include /etc/ssh/sshd_config.d/*.conf

      Port 22
      PermitRootLogin prohibit-password
      PasswordAuthentication yes
      KbdInteractiveAuthentication no
      UsePAM yes
      X11Forwarding no
      PrintMotd no
      Subsystem sftp /usr/lib/openssh/sftp-server
      CONF

      install -d /etc/ssh/sshd_config.d
      rm -f /etc/ssh/sshd_config.d/*.conf
      cat > /etc/ssh/sshd_config.d/50-cloud-init.conf <<'CONF'
      # Written by the image build. Do not edit by hand.
      PasswordAuthentication yes
      CONF

      # systemd writes /run/nologin at boot and systemd-user-sessions.service
      # removes it once the box is up. That unit is not running here, so without
      # this every non-root login is refused by PAM before authentication is even
      # reached — a lockout that has nothing to do with the lesson.
      systemctl start systemd-user-sessions.service >/dev/null 2>&1 || true
      rm -f /run/nologin

      systemctl unmask ssh.service >/dev/null 2>&1 || true
      systemctl enable --now ssh.service >/dev/null 2>&1
      systemctl reload ssh.service >/dev/null 2>&1 || true

      # ---- the ops workstation's key, on the other box ------------------
      #
      # Generated here and left in /lab, which both boxes share. The private
      # half never needs to be on this box: the point of the exercise is that
      # the far end can get in without one.
      rm -f /lab/ops_key /lab/ops_key.pub
      ssh-keygen -q -t ed25519 -N '' -C 'ops workstation' -f /lab/ops_key
      chmod 600 /lab/ops_key

      # ---- the session that is already open -----------------------------
      #
      # Stands in for the terminal you are reading this in: a login that exists
      # now, that has to still exist afterwards, and that is the only thing
      # standing between a bad change and a box nobody can reach.
      install -d -m 700 /root/.ssh
      rm -f /root/.ssh/ops_session /root/.ssh/ops_session.pub
      ssh-keygen -q -t ed25519 -N '' -C 'ops session' -f /root/.ssh/ops_session
      cat /root/.ssh/ops_session.pub > /root/.ssh/authorized_keys
      chmod 600 /root/.ssh/authorized_keys
      cp /root/.ssh/ops_session /lab/grader_key
      chmod 600 /lab/grader_key

      cat > /usr/local/bin/ops-session <<'SESS'
      #!/bin/sh
      # Holds one SSH session open and reports its heartbeat on this end of it.
      #
      # The remote side only prints; the file is written by the local client as
      # the bytes arrive. That way the timestamp goes stale the moment the
      # connection dies, which is the thing being measured — a loop running on
      # the far side would happily outlive the session that started it.
      ssh -i /root/.ssh/ops_session \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        -o LogLevel=ERROR -o ServerAliveInterval=5 \
        root@127.0.0.1 \
        'while true; do date +%s; sleep 2; done' \
      | while read -r ts; do
          printf '%s\n' "$ts" > /run/ops-session
          chmod 644 /run/ops-session
        done
      SESS
      chmod 755 /usr/local/bin/ops-session

      printf '[Unit]\nDescription=the session that was already open\nAfter=ssh.service\n\n[Service]\nExecStart=/usr/local/bin/ops-session\nRestart=no\n\n[Install]\nWantedBy=multi-user.target\n' \
        > /etc/systemd/system/ops-session.service
      systemctl daemon-reload
      systemctl enable ops-session.service >/dev/null 2>&1
      systemctl restart ops-session.service >/dev/null 2>&1

      for _ in $(seq 1 20); do
        [ -s /run/ops-session ] && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      Security has given us until Friday to turn off SSH password authentication
      on this box. It is 172.31.0.10; the ops workstation is the other box on
      this network, 172.31.0.11, and its key pair is in /lab.

      Right now this box takes passwords and nothing else:

        deploy / deploy-2026

      There is no authorized_keys anywhere. If password authentication goes off
      before a key works, the next person to connect does not get in, and the
      only way back is a console nobody has.

      There is also a session already open on this box — ops-session.service,
      writing a timestamp to /run/ops-session every two seconds. It is standing
      in for your own terminal. If it dies, assume you did that to yourself.

      Four things to do.

      1. Make the deploy user reachable by key from the ops workstation, using
         the key pair already in /lab.

      2. Turn password authentication off — actually off, as sshd sees it, not
         just in the file you edited. `sshd -T` prints the running
         configuration; read it rather than trusting the file.

      3. Do it without dropping the open session and without leaving sshd
         refusing to start. `sshd -t` checks a config before you apply it, and
         reload is not restart.

      4. Write /root/answers/ssh.md, exactly two lines:

           overriding_file: <the file whose setting beat the one you edited>
           first_or_last_wins: <first or last>

      The second line is the rule that explains the first: when the same keyword
      appears twice, sshd keeps one of them. Find out which.
      Q

      echo "scenario ready — passwords work, keys do not, and one session is already open"

  verify_done:
    service: peer
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      BOX=172.31.0.10
      SSH="ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -o LogLevel=ERROR -o ConnectTimeout=5 -o BatchMode=yes"

      if [ ! -s /lab/ops_key ]; then
        echo "not yet: /lab/ops_key is missing on the ops workstation. The scenario"
        echo "         puts it there; if it was moved, put it back."
        exit 1
      fi
      chmod 600 /lab/ops_key /lab/grader_key 2>/dev/null || true

      # ---- can the far box get in as deploy, with a key? ----------------
      #
      # This runs on 172.31.0.11, which is the whole point: a key login that
      # only works from the box you are already on proves nothing.
      who=$($SSH -i /lab/ops_key deploy@$BOX 'id -un' 2>&1 || true)
      if [ "$who" != "deploy" ]; then
        echo "not yet: key login as deploy from the ops workstation does not work."
        echo "         ssh said: $(printf '%s' "$who" | head -1)"
        case "$who" in
          *"Permission denied"*)
            echo "         The public half of /lab/ops_key has to be in that user's"
            echo "         ~/.ssh/authorized_keys on 172.31.0.10, owned by them, and"
            echo "         sshd is strict about the permissions on the directory and"
            echo "         the file — 700 and 600."
            ;;
          *"Connection refused"*|*"No route"*|*"timed out"*)
            echo "         Nothing is listening on 22. If sshd was restarted with a"
            echo "         config it will not accept, it is down now and this is what"
            echo "         being locked out looks like from the outside."
            ;;
        esac
        exit 1
      fi

      # ---- is the box still offering passwords? -------------------------
      #
      # PreferredAuthentications=none makes the server answer with the list of
      # methods it is willing to try for this user. That is the server's own
      # statement, not a guess from the client side.
      offer=$($SSH -o PreferredAuthentications=none -o PubkeyAuthentication=no \
                deploy@$BOX true 2>&1 || true)
      if echo "$offer" | grep -qi 'password\|keyboard-interactive'; then
        echo "not yet: 172.31.0.10 still offers password authentication to deploy."
        echo "         It answered: $(printf '%s' "$offer" | grep -i 'permission denied' | head -1)"
        echo "         The methods in those brackets are what sshd is running with,"
        echo "         whatever any file says. Compare:"
        echo "           grep -ri passwordauthentication /etc/ssh/"
        echo "           sshd -T | grep -i passwordauthentication"
        exit 1
      fi

      # ---- and does sshd agree, in its own words? -----------------------
      effective=$($SSH -i /lab/grader_key root@$BOX 'sshd -T 2>/dev/null | grep -i "^passwordauthentication"' 2>&1 || true)
      case "$effective" in
        *no*)
          ;;
        *yes*)
          echo "not yet: sshd -T on the box says: $effective"
          echo "         That is the running configuration. A setting in"
          echo "         /etc/ssh/sshd_config can be overridden by a file included"
          echo "         before it, and sshd keeps the first value it reads."
          exit 1
          ;;
        *)
          echo "not yet: could not read sshd -T from the box: $effective"
          exit 1
          ;;
      esac

      # ---- did the session that was already open survive? ---------------
      stamp=$($SSH -i /lab/grader_key root@$BOX 'cat /run/ops-session 2>/dev/null' 2>&1 || true)
      now=$($SSH -i /lab/grader_key root@$BOX 'date +%s' 2>&1 || true)
      case "$stamp$now" in
        *[!0-9]*|"")
          echo "not yet: the session that was already open is gone — nothing is"
          echo "         writing /run/ops-session any more."
          echo "         pkill sshd takes every established session with it. reload"
          echo "         re-reads the config and touches none of them."
          exit 1
          ;;
      esac
      age=$((now - stamp))
      if [ "$age" -gt 15 ]; then
        echo "not yet: the open session stopped writing $age seconds ago. It did not"
        echo "         survive the change. A reload leaves established sessions"
        echo "         alone; killing the daemon's process group does not."
        exit 1
      fi

      # ---- the answers ---------------------------------------------------
      answers=$($SSH -i /lab/grader_key root@$BOX 'cat /root/answers/ssh.md 2>/dev/null' 2>&1 || true)
      if [ -z "$answers" ]; then
        echo "not yet: /root/answers/ssh.md on the box is missing or empty."
        exit 1
      fi

      low=$(printf '%s\n' "$answers" | tr 'A-Z' 'a-z')
      file=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*overriding_file[[:space:]]*[:=][[:space:]]*\(.*\)$/\1/p' | head -1)
      order=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*first_or_last_wins[[:space:]]*[:=][[:space:]]*\(.*\)$/\1/p' | head -1)

      fail=0

      case "$file" in
        *cloud-init*)
          ;;
        "")
          fail=1
          echo "not yet: no overriding_file line in /root/answers/ssh.md."
          ;;
        */etc/ssh/sshd_config)
          fail=1
          echo "not yet: you said overriding_file=$file."
          echo "         That is the file that lost. Its first line includes another"
          echo "         directory, and something in there had already answered."
          ;;
        *)
          fail=1
          echo "not yet: you said overriding_file=$file."
          echo "           grep -ri passwordauthentication /etc/ssh/"
          echo "         names every file with an opinion. One of them is not the one"
          echo "         you edited."
          ;;
      esac

      case "$order" in
        *first*)
          ;;
        "")
          fail=1
          echo "not yet: no first_or_last_wins line in /root/answers/ssh.md."
          ;;
        *last*)
          fail=1
          echo "not yet: you said first_or_last_wins=$order."
          echo "         That is how most config formats behave and it is why this one"
          echo "         catches people. sshd_config is the other way round, and the"
          echo "         Include on line one is what puts the drop-in ahead of"
          echo "         everything below it."
          ;;
        *)
          fail=1
          echo "not yet: you said first_or_last_wins=$order."
          echo "         One word: first or last."
          ;;
      esac

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — deploy logs in by key from the other box, sshd offers no password"
      echo "       authentication to anyone, and the session that was open before you"
      echo "       started is still open."
