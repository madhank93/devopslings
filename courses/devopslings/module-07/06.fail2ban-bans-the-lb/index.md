---
kind: lesson
title: "the brute-force jail is about to ban the load balancer"
description: |
  A fail2ban jail guards the login endpoint, and every failure it counts comes
  from the load balancer's address, because that is the peer every proxied
  request arrives from. Exempting the load balancer stops the outage and blinds
  the jail. The real fix is counting failures against the client address the
  load balancer vouches for, without believing the same header from anyone else.
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

      rm -f /etc/fail2ban/jail.local /etc/fail2ban/filter.d/web-login.conf \
            /etc/fail2ban/filter.d/web-login.local /etc/fail2ban/jail.d/*.local \
            /var/log/app/access.log /root/answers/fail2ban.md
      install -d /root/answers /var/log/app

      # The login service's access log: nginx "combined" format with
      # "$http_x_forwarded_for" appended. Timestamps are recent so they fall
      # inside findtime.
      python3 - <<'PY'
      import datetime, random
      random.seed(7)
      LB = "10.9.0.9"
      now = datetime.datetime.now(datetime.timezone.utc)
      rows = []

      def req(peer, xff, method, path, status, ua):
          rows.append((peer, xff, method, path, status, ua))

      # The load balancer probes an endpoint that now requires auth.
      for _ in range(15):
          req(LB, "-", "GET", "/api/status", 401, "lb-healthcheck/1.0")
      # Real users through the load balancer, one or two typos each.
      for u in ["198.51.100.23", "198.51.100.41", "198.51.100.87", "198.51.100.112"]:
          for _ in range(random.choice([1, 2])):
              req(LB, u, "POST", "/login", 401, "Mozilla/5.0")
          req(LB, u, "POST", "/login", 200, "Mozilla/5.0")
      # A credential-stuffing run through the load balancer, forging a fresh
      # X-Forwarded-For value on every request; the LB appends the real peer.
      for i in range(10):
          req(LB, f"10.{random.randint(0,255)}.{random.randint(0,255)}.{i+1}, 203.0.113.66",
              "POST", "/login", 401, "python-requests/2.31")
      # A host reaching the backend port directly, claiming to be a real user.
      for _ in range(8):
          req("192.0.2.77", "198.51.100.23", "POST", "/login", 401, "curl/8.5.0")
      # Internal monitoring, direct, logged in fine.
      req("10.9.0.30", "-", "POST", "/login", 200, "check_http/2.3")

      random.shuffle(rows)
      with open("/var/log/app/access.log", "w") as f:
          for i, (peer, xff, method, path, status, ua) in enumerate(rows):
              t = (now - datetime.timedelta(seconds=(len(rows) - i) * 3)).strftime("%d/%b/%Y:%H:%M:%S +0000")
              f.write(f'{peer} - - [{t}] "{method} {path} HTTP/1.1" {status} 17 "-" "{ua}" "{xff}"\n')
      PY

      cat > /etc/fail2ban/filter.d/web-login.conf <<'CFG'
      # Failed logins (HTTP 401) in the login service's access log.
      [Definition]
      failregex = ^<HOST> \S+ \S+ \[[^]]*\] "[A-Z]+ [^"]*" 401 
      ignoreregex =
      CFG

      cat > /etc/fail2ban/jail.local <<'CFG'
      [DEFAULT]
      backend = polling

      [web-login]
      enabled  = true
      filter   = web-login
      logpath  = /var/log/app/access.log
      maxretry = 5
      findtime = 600
      bantime  = 3600
      CFG

      fail2ban-client -t >/dev/null

      cat > /root/questions.txt <<'Q'
      The web-login jail protects /login on this box. Ask it what it would do with
      the current access log:

        $ fail2ban-regex /var/log/app/access.log web-login

      The one address it would ban is 10.9.0.9, the load balancer. Every user
      reaches the site through it.

      Fix the jail so that, for traffic like this:

        - whoever is actually hammering /login gets banned,
        - the load balancer is never banned,
        - users who mistype a password once or twice are never banned,
        - nobody can get another person banned, or dodge a ban, by sending a
          made-up X-Forwarded-For header.

      Keep the jail enabled. Config lives in /etc/fail2ban (jail.local and
      filter.d/web-login.conf). Check your work with fail2ban-regex and
      fail2ban-client -t / -d. The grader runs the jail for real against fresh
      traffic with different client addresses.

      Then write /root/answers/fail2ban.md with two lines:

        wrongly_banned_ip: <the address the original jail would have banned>
        real_client_in: <the log field that carries the real client address>
      Q

      echo "scenario ready: web-login jail about to ban the load balancer at 10.9.0.9"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      set -e

      lb=10.9.0.9
      ans=/root/answers/fail2ban.md

      if ! fail2ban-client -t >/dev/null 2>&1; then
        echo "not yet: fail2ban-client -t rejects the configuration:"
        fail2ban-client -t 2>&1 | grep -iE 'error|fail' | head -2 | sed 's/^/         /' || true
        exit 1
      fi
      if ! fail2ban-client -d 2>/dev/null | grep -qE "\['add', 'web-login'"; then
        echo "not yet: there is no enabled web-login jail. It has to keep running;"
        echo "         switching it off stops the outage and every ban with it."
        exit 1
      fi

      # Run the student's jail for real, in a private fail2ban-server, against
      # fresh traffic whose addresses are drawn at random each run. Only the
      # log path and the ban action are overridden.
      t=$(mktemp -d)
      trap 'fail2ban-client -c "$t/conf" stop >/dev/null 2>&1 || true; rm -rf "$t"' EXIT
      cp -a /etc/fail2ban "$t/conf"
      cat > "$t/conf/fail2ban.d/zzz-verify.local" <<EOF
      [Definition]
      socket = $t/f2b.sock
      pidfile = $t/f2b.pid
      dbfile = :memory:
      logtarget = $t/f2b.log
      EOF
      cat > "$t/conf/jail.d/zzz-verify.local" <<EOF
      [sshd]
      enabled = false

      [web-login]
      logpath = $t/access.log
      action = dummy[target=$t/dummy]
      EOF

      python3 - "$t" <<'PY'
      import datetime, json, random, sys
      d = sys.argv[1]
      LB = "10.9.0.9"
      r = random.Random()
      pool = r.sample(range(2, 250), 8)
      s = {
          "attacker": f"203.0.113.{pool[0]}",
          "spoofer": f"192.0.2.{pool[1]}",
          "framed": f"198.51.100.{pool[2]}",
          "users": [f"198.51.100.{p}" for p in pool[3:6]],
          "quiet": f"10.9.0.{pool[6] % 200 + 40}",
      }
      rows = []
      for _ in range(12):
          rows.append((LB, "-", "GET /api/status", 401))
      for u in s["users"] + [s["framed"]]:
          rows += [(LB, u, "POST /login", 401)] * 2 + [(LB, u, "POST /login", 200)]
      for i in range(10):
          rows.append((LB, f"10.{r.randint(0,255)}.{r.randint(0,255)}.{i+1}, {s['attacker']}", "POST /login", 401))
      for _ in range(8):
          rows.append((s["spoofer"], s["framed"], "POST /login", 401))
      rows.append((s["quiet"], "-", "POST /login", 401))
      r.shuffle(rows)
      now = datetime.datetime.now(datetime.timezone.utc)
      with open(f"{d}/access.log", "w") as f:
          for i, (peer, xff, req, st) in enumerate(rows):
              ts = (now - datetime.timedelta(seconds=len(rows) - i)).strftime("%d/%b/%Y:%H:%M:%S +0000")
              f.write(f'{peer} - - [{ts}] "{req} HTTP/1.1" {st} 17 "-" "test" "{xff}"\n')
      json.dump(s, open(f"{d}/cast.json", "w"))
      PY
      get() { python3 -c "import json,sys; v=json.load(open('$t/cast.json'))['$1']; print(' '.join(v) if isinstance(v, list) else v)"; }
      attacker=$(get attacker); spoofer=$(get spoofer); framed=$(get framed)
      users=$(get users); quiet=$(get quiet)

      if ! fail2ban-client -c "$t/conf" start >/dev/null 2>&1; then
        echo "not yet: fail2ban-server would not start with this configuration:"
        grep -iE 'error' "$t/f2b.log" 2>/dev/null | tail -2 | sed 's/^/         /' || true
        exit 1
      fi
      # Polling reads the whole file on start; give it a moment to settle.
      banned=""
      for _ in $(seq 1 15); do
        sleep 1
        now=$(fail2ban-client -c "$t/conf" status web-login 2>/dev/null \
              | sed -n 's/.*Banned IP list:[[:space:]]*//p')
        [ -n "$now" ] && [ "$now" = "$banned" ] && break
        banned=$now
      done
      is_banned() { printf ' %s ' "$banned" | grep -qF " $1 "; }
      shown=${banned:-nobody}

      traffic() {
        echo "         test traffic: attacker $attacker (10 failures via the load balancer);"
        echo "         $spoofer (8 failures direct, sending X-Forwarded-For: $framed);"
        echo "         users $users $framed (2 failures each via the load balancer);"
        echo "         $quiet (1 failure direct); load balancer health checks (12 x 401)."
        echo "         jail banned: $shown"
      }

      if is_banned "$lb"; then
        echo "not yet: the jail banned the load balancer, $lb. Whatever it forwards,"
        echo "         and its own health checks, the load balancer must never be banned."
        traffic
        exit 1
      fi
      for ok in $users $quiet; do
        if is_banned "$ok"; then
          echo "not yet: the jail banned $ok, which failed at most 2 logins."
          traffic
          exit 1
        fi
      done
      if is_banned "$framed"; then
        echo "not yet: the jail banned $framed, who failed 2 logins. The rest of its"
        echo "         count came from $spoofer, which connected directly (not through"
        echo "         the load balancer) and wrote $framed into X-Forwarded-For itself."
        traffic
        exit 1
      fi
      if ! is_banned "$attacker"; then
        echo "not yet: $attacker failed 10 logins through the load balancer and was not"
        echo "         banned. Those requests arrive from peer $lb with X-Forwarded-For"
        echo "         like '10.x.y.z, $attacker': the load balancer appends the peer it"
        echo "         saw, so only the last entry is its word; the rest is client input."
        traffic
        exit 1
      fi
      if ! is_banned "$spoofer"; then
        echo "not yet: $spoofer failed 8 logins connecting directly and was not banned."
        echo "         A client that is not the load balancer is identified by its own"
        echo "         address, whatever header it sends."
        traffic
        exit 1
      fi

      if [ ! -s "$ans" ]; then
        echo "not yet: /root/answers/fail2ban.md is missing or empty."
        echo "         Two lines: wrongly_banned_ip and real_client_in."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < "$ans")
      a_ip=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*wrongly_banned_ip[[:space:]]*[:=][[:space:]]*\([0-9.]*\).*/\1/p' | head -1)
      a_in=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*real_client_in[[:space:]]*[:=]\(.*\)/\1/p' | head -1)
      if [ "$a_ip" != "$lb" ]; then
        echo "not yet: wrongly_banned_ip says '${a_ip:-nothing}'. Which address did the"
        echo "         original jail count every failure against?"
        exit 1
      fi
      if ! printf '%s\n' "$a_in" | grep -Eq '\b(x-forwarded-for|xff|http_x_forwarded_for)\b'; then
        echo "not yet: real_client_in says '$(printf '%s' "$a_in" | sed 's/^ *//')'. Name the"
        echo "         header/log field that carries the client's address past the proxy."
        exit 1
      fi

      echo "PASS: the jail banned the attacker behind the load balancer and the"
      echo "      direct spoofer, and never the load balancer or the real users."
---
