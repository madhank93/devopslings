---
kind: lesson
title: "harden sshd without locking yourself out of the box you are on"
description: |
  sshd accepts root and password logins; both have to go. The change itself is
  two directives. The discipline is the lesson: disabling passwords before the
  replacement key works locks the account out permanently, so the order is
  install the key, prove it, then take passwords away — validating the config
  and reloading rather than restarting at every step.
name: ssh-hardening
slug: ssh-hardening
createdAt: "2026-08-26"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 240
    run: |
      set -e

      # Idempotent teardown
      userdel -r alice 2>/dev/null || true
      rm -f /root/deploy_key /root/deploy_key.pub /root/answers/ssh.md

      # Create the account with a password (no key yet) and the answers dir
      useradd -m -s /bin/bash alice
      echo 'alice:secret123' | chpasswd
      install -d /root/answers

      # Generate the deploy keypair
      rm -f /root/deploy_key /root/deploy_key.pub
      ssh-keygen -t ed25519 -N '' -f /root/deploy_key -C alice@laptop >/dev/null

      # Make sshd run as a plain service, not socket-activated, and give it host keys
      systemctl mask ssh.socket 2>/dev/null || true
      ssh-keygen -A >/dev/null 2>&1

      # Write the deliberately unhardened config
      cat > /etc/ssh/sshd_config <<'CFG'
      Port 22
      PermitRootLogin yes
      PasswordAuthentication yes
      PubkeyAuthentication yes
      Subsystem sftp /usr/lib/openssh/sftp-server
      CFG
      sshd -t
      systemctl enable ssh.service >/dev/null 2>&1 || true
      systemctl restart ssh.service

      # Write questions file
      cat > /root/questions.txt <<'Q'
      sshd on this box accepts root logins and password logins — both should be off.
      Harden it so:

        - root cannot log in over SSH        (PermitRootLogin no)
        - passwords are not accepted         (PasswordAuthentication no)
        - alice can still get in with her key

      The catch is the third line. Turning off password authentication while alice
      has no key installed locks her out for good — the same way a careless change to
      a real server drops the session you are sitting in and every future one. So the
      order matters: install alice's key first, confirm it works, and only then take
      passwords away.

      alice's public key is in /root/deploy_key.pub (the matching private key is
      /root/deploy_key, standing in for her laptop). Install it into her
      authorized_keys.

      Validate every change before you apply it — sshd will happily be handed a
      config it cannot parse:

        $ sshd -t          # exits non-zero and prints the error if the config is bad
        $ systemctl reload ssh    # reload, not restart: it re-reads config without
                                  #   dropping connections

      Then write /root/answers/ssh.md with exactly three lines:

        permit_root_login: <the value you set>
        password_authentication: <the value you set>
        validated_with: <the command that checks a config before it is applied>
      Q

      echo "scenario ready — sshd up, unhardened, alice has a password and a key waiting"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 240
    run: |
      set -e

      ans=/root/answers/ssh.md

      # It has to be listening. A dead daemon is the clearest failure, so check
      # it first.
      if ! ss -ltn 2>/dev/null | grep -q ':22 '; then
        echo "not yet: nothing is listening on port 22."
        echo "         Start the service: systemctl reload ssh (or restart if it"
        echo "         is not running yet)."
        exit 1
      fi

      # The config sshd is running with has to parse. sshd -t is the same check
      # the learner is told to run; a config that fails it is one a restart
      # would refuse, taking the daemon down. The privsep dir is shipped by the
      # image, but recreate it if a stopped service cleaned it away.
      install -d -m 0755 /run/sshd 2>/dev/null || true
      if ! sshd -t 2>/dev/null; then
        echo "not yet: sshd -t rejects the current /etc/ssh/sshd_config:"
        sshd -t 2>&1 | sed 's/^/         /' | head -3
        echo "         A config sshd cannot parse is one that would drop the"
        echo "         daemon on the next restart. Fix it, then reload."
        exit 1
      fi

      # The two hardening directives, read from the daemon's *effective* config
      # rather than by grepping the file — sshd -T resolves includes, case and
      # defaults, so this is what sshd truly believes.
      eff=$(sshd -T 2>/dev/null)
      pra=$(printf '%s\n' "$eff" | awk 'tolower($1)=="permitrootlogin"{print tolower($2)}' | head -1)
      pwa=$(printf '%s\n' "$eff" | awk 'tolower($1)=="passwordauthentication"{print tolower($2)}' | head -1)

      if [ "$pra" != "no" ]; then
        echo "not yet: PermitRootLogin is effectively '$pra'. Root must not be"
        echo "         able to log in over SSH — set PermitRootLogin no and reload."
        exit 1
      fi
      if [ "$pwa" != "no" ]; then
        echo "not yet: PasswordAuthentication is effectively '$pwa'. Passwords"
        echo "         must be refused — set PasswordAuthentication no and reload."
        exit 1
      fi

      # The file can say no while the running daemon still says yes: edits only
      # take effect on reload. Ask the live daemon which methods it offers.
      # Retried briefly: a reload re-executes sshd, and the listener blinks.
      offered=""
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        offered=$(ssh -n -v -o BatchMode=yes -o PreferredAuthentications=none \
                    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                    -o ConnectTimeout=5 alice@127.0.0.1 true 2>&1 \
                  | sed -n 's/.*Authentications that can continue: //p' | head -1 || true)
        [ -n "$offered" ] && break
        sleep 0.5
      done
      if printf '%s' "$offered" | grep -qw password; then
        echo "not yet: sshd_config says PasswordAuthentication no, but the running"
        echo "         daemon still offers: $offered"
        echo "         The file is only read when sshd starts or reloads."
        exit 1
      fi

      # Root login, tried for real with a throwaway key that is removed again,
      # so the check leaves /root/.ssh as it found it.
      probe=$(mktemp -d)
      ssh-keygen -q -t ed25519 -N '' -f "$probe/k" -C grader-probe
      install -d -m 700 /root/.ssh
      [ -f /root/.ssh/authorized_keys ] && cp -p /root/.ssh/authorized_keys "$probe/ak"
      cat "$probe/k.pub" >> /root/.ssh/authorized_keys
      rootlogin=$(ssh -n -i "$probe/k" -o StrictHostKeyChecking=no \
                    -o UserKnownHostsFile=/dev/null -o BatchMode=yes \
                    -o ConnectTimeout=5 root@127.0.0.1 'id -un' 2>/dev/null || true)
      if [ -f "$probe/ak" ]; then cp -p "$probe/ak" /root/.ssh/authorized_keys
      else rm -f /root/.ssh/authorized_keys; fi
      rm -rf "$probe"
      if [ "$rootlogin" = root ]; then
        echo "not yet: sshd_config says PermitRootLogin no, but the running daemon"
        echo "         still let root in with a key. The file is only read when sshd"
        echo "         starts or reloads."
        exit 1
      fi

      # The invariant the whole lesson turns on: after hardening, alice's key
      # still gets her in. If passwords were disabled before her key was
      # installed, this is where the lockout shows up — the login simply fails.
      # Single-quote the remote command so it runs on the far side as alice.
      # Double quotes would expand $(id -un) here, in the grader's own root
      # shell, and prove nothing about who logged in.
      login=$(ssh -n -i /root/deploy_key \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o BatchMode=yes -o ConnectTimeout=5 \
                alice@127.0.0.1 'id -un' 2>/dev/null || true)
      if [ "$login" != "alice" ]; then
        echo "not yet: alice cannot log in with her key, and passwords are off —"
        echo "         she is locked out."
        echo "         Her public key is /root/deploy_key.pub; it belongs in"
        echo "         /home/alice/.ssh/authorized_keys, owned by alice, mode 600,"
        echo "         inside a .ssh directory that is mode 700. sshd ignores a"
        echo "         key file that anyone but the owner can write."
        exit 1
      fi

      # The written summary.
      if [ ! -s "$ans" ]; then
        echo "not yet: /root/answers/ssh.md is missing or empty."
        echo "         Three lines: permit_root_login, password_authentication,"
        echo "         validated_with."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      a_pra=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*permit_root_login[[:space:]]*[:=][[:space:]]*\([a-z-]*\).*/\1/p' | head -1)
      a_pwa=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*password_authentication[[:space:]]*[:=][[:space:]]*\([a-z-]*\).*/\1/p' | head -1)
      a_val=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*validated_with[[:space:]]*[:=][[:space:]]*//p' | head -1)

      if [ "$a_pra" != "no" ] || [ "$a_pwa" != "no" ]; then
        echo "not yet: ssh.md should record permit_root_login: no and"
        echo "         password_authentication: no — the values you set."
        exit 1
      fi
      if ! printf '%s' "$a_val" | grep -qE 'sshd[[:space:]]*-t'; then
        echo "not yet: validated_with says '${a_val:-nothing}'. Name the command"
        echo "         that checks a config for errors before it is applied."
        exit 1
      fi

      echo "PASS — root and password logins are off, alice still gets in with her"
      echo "       key, and the config that is live is one sshd could parse."
