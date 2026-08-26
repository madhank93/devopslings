---
kind: lesson
title: "the brute-force jail is about to ban the load balancer"
description: |
  A fail2ban sshd jail is counting failed logins, and every one of them arrives
  from the load balancer's address, because that is the only source the box can
  see behind it. Twelve failures, one apparent attacker, and it is the address
  every real user shares — so the ban that is about to fire takes the whole site
  down. The fix is to exempt the load balancer without switching the jail off.
name: fail2ban-bans-the-lb
slug: fail2ban-bans-the-lb
createdAt: "2026-08-26"

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
      rm -f /etc/fail2ban/jail.local /var/log/auth.log /root/answers/fail2ban.md

      # Create the answers dir
      install -d /root/answers

      # Write an auth log full of failed SSH logins from 10.9.0.9
      python3 - <<'PY'
      import datetime
      now = datetime.datetime.now()
      lines = []
      for i in range(12):
          t = (now - datetime.timedelta(seconds=(12 - i) * 4)).strftime("%b %d %H:%M:%S")
          lines.append(
              f"{t} box sshd[{2000+i}]: Failed password for invalid user admin "
              f"from 10.9.0.9 port {50000+i} ssh2"
          )
      with open("/var/log/auth.log", "w") as f:
          f.write("\n".join(lines) + "\n")
      PY

      # Write the jail configuration
      cat > /etc/fail2ban/jail.local <<'CFG'
      [DEFAULT]
      backend = polling

      [sshd]
      enabled  = true
      logpath  = /var/log/auth.log
      maxretry = 5
      findtime = 600
      bantime  = 3600
      CFG

      # Validate the config
      fail2ban-client -t

      # Write questions file
      cat > /root/questions.txt <<'Q'
      The SSH brute-force jail is doing its job too well: it is about to ban the load
      balancer, and take every user offline with it.

      Every SSH session reaches this box through the load balancer at 10.9.0.9, so
      every failed login is logged as coming FROM 10.9.0.9 — the real clients are
      invisible behind it. Watch what fail2ban sees:

        $ fail2ban-regex /var/log/auth.log sshd

      Twelve failures, all from 10.9.0.9, against a maxretry of 5. The moment the jail
      runs, it bans 10.9.0.9 — which is not an attacker, it is the one address every
      legitimate user shares. The whole site goes dark.

      Stop the jail from banning the load balancer, without disabling it (real
      attackers still have to be caught). The directive that exempts an address from a
      jail is ignoreip; add the load balancer to it.

      Validate before you rely on it:

        $ fail2ban-client -t          # config is valid
        $ fail2ban-client -d | grep -i ignoreip

      Then write /root/answers/fail2ban.md with exactly two lines:

        wrongly_banned_ip: <the address the jail was about to ban>
        fixed_with: <the jail directive that exempts an address>
      Q

      echo "scenario ready — sshd jail about to ban the load balancer at 10.9.0.9"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e

      ans=/root/answers/fail2ban.md
      lb=10.9.0.9

      # The config has to parse. A jail.local with a typo is one fail2ban would
      # refuse to load, leaving the box with no protection at all.
      if ! fail2ban-client -t >/dev/null 2>&1; then
        echo "not yet: fail2ban-client -t rejects the configuration:"
        fail2ban-client -t 2>&1 | grep -iE 'error|fail' | head -2 | sed 's/^/         /'
        exit 1
      fi

      # Read the effective, parsed configuration — not the raw file — so this
      # sees exactly what fail2ban would load, includes and defaults resolved.
      dump=$(fail2ban-client -d 2>/dev/null || true)

      # The jail must still exist. "Fixing" the outage by deleting the sshd jail
      # stops the ban and also stops catching any real attacker.
      if ! printf '%s\n' "$dump" | grep -qE "\['add', 'sshd'"; then
        echo "not yet: there is no enabled sshd jail any more. The jail has to"
        echo "         keep running — the fix is to exempt the load balancer from"
        echo "         it, not to switch it off."
        exit 1
      fi

      # The load balancer must be in the sshd jail's ignore list. addignoreip in
      # the dump is the resolved ignoreip for the jail.
      if ! printf '%s\n' "$dump" | grep -E "addignoreip" | grep -q "$lb"; then
        echo "not yet: the sshd jail does not ignore $lb."
        echo "         Every failure is logged from the load balancer's address,"
        echo "         so the jail is about to ban it and cut off every user."
        echo "         Add it to ignoreip in the sshd jail."
        exit 1
      fi

      # The written summary.
      if [ ! -s "$ans" ]; then
        echo "not yet: /root/answers/fail2ban.md is missing or empty."
        echo "         Two lines: wrongly_banned_ip and fixed_with."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      a_ip=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*wrongly_banned_ip[[:space:]]*[:=][[:space:]]*\([0-9.]*\).*/\1/p' | head -1)
      a_fix=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*fixed_with[[:space:]]*[:=][[:space:]]*\([a-z_]*\).*/\1/p' | head -1)

      if [ "$a_ip" != "$lb" ]; then
        echo "not yet: wrongly_banned_ip says '${a_ip:-nothing}'. The address every"
        echo "         failed login appears to come from is the load balancer's."
        exit 1
      fi
      if [ "$a_fix" != "ignoreip" ]; then
        echo "not yet: fixed_with says '${a_fix:-nothing}'. Name the jail directive"
        echo "         that exempts an address from being banned."
        exit 1
      fi

      echo "PASS — the sshd jail still runs, but the load balancer at $lb is"
      echo "       exempt, so a shared front door is no longer a single point of"
      echo "       lockout."
