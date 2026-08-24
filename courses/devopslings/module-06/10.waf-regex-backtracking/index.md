---
kind: lesson
title: "one rule, every request, and a regex that stops to think"
description: |
  The edge filter in front of the site evaluates a rule against every request
  before anything is proxied. One rule takes seconds to decide on an ordinary
  URL, and because the filter answers one request at a time, seconds is the
  whole site. The rule is not wrong about what to block — it is wrong about how
  long it is allowed to take.
name: waf-regex-backtracking
slug: waf-regex-backtracking
createdAt: "2026-08-24"
timingSensitive: true

sandbox:
  stack: web-stack
  service: web

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e

      systemctl stop nginx.service waf.service 2>/dev/null || true
      rm -f /etc/nginx/sites-enabled/* /root/answers/waf.md
      install -d /etc/waf /root/answers /root/waf-corpus

      ready=""
      for _ in $(seq 1 40); do
        if curl -s -m 2 http://172.32.0.11:8080/health 2>/dev/null | grep -q ok; then
          ready=yes
          break
        fi
        sleep 0.5
      done
      if [ -z "$ready" ]; then
        echo "the origin on 172.32.0.11:8080 never came up"
        exit 1
      fi

      # ---- the rule that shipped ------------------------------------------
      #
      # Written to catch an assignment expression in a request — the shape of an
      # injected payload. It is quoted here through python rather than a shell
      # heredoc because the pattern contains both quote characters.
      python3 - <<'PY'
      rule = r"""(?:\"|'|\]|\}|\\|\d|(?:nan|infinity|true|false|null|undefined|symbol|math)|\+)+[)]*;?((?:\s|-|~|!|{}|\|\||\+)*.*(?:.*=.*))"""
      with open("/etc/waf/rules.conf", "w") as f:
          f.write("# One rule per line: name, a TAB, then the regex.\n")
          f.write("# The filter re-reads this file whenever it changes.\n")
          f.write("sqli-inline-assignment\t" + rule + "\n")
      PY

      # No budget: a rule is allowed to take as long as it likes, which is the
      # setting nobody chose and everybody has.
      printf 'budget_ms = 0\n' > /etc/waf/waf.conf

      # ---- what the rule is for, written down ------------------------------
      #
      # A rule with no test corpus can be "fixed" by deleting it. These are the
      # requests it exists to block and the ones it must not touch.
      cat > /root/waf-corpus/block <<'CORPUS'
      /api?x=1;a=b
      /q?p=';a=1
      CORPUS
      cat > /root/waf-corpus/allow <<'CORPUS'
      /health
      /asset.js?v=3
      CORPUS

      systemctl daemon-reload
      systemctl start waf.service
      for _ in $(seq 1 40); do
        curl -s -m 2 http://127.0.0.1:8090/healthz 2>/dev/null | grep -q ok && break
        sleep 0.5
      done

      # ---- the edge ---------------------------------------------------------
      #
      # auth_request turns every request into two: nginx asks the filter about
      # it and waits for the answer before proxying anything. Whatever the
      # filter's latency is, it is the site's latency.
      cat > /etc/nginx/sites-enabled/edge <<'CFG'
      server {
          listen 80 default_server;
          server_name _;

          location = /_waf {
              internal;
              proxy_pass http://127.0.0.1:8090/check;
              proxy_pass_request_body off;
              proxy_set_header Content-Length "";
              proxy_set_header X-Original-URI $request_uri;
          }

          location / {
              auth_request /_waf;
              proxy_pass http://172.32.0.11:8080;
          }
      }
      CFG

      nginx -t >/dev/null 2>&1 || { echo "the edge config does not parse"; nginx -t; exit 1; }
      systemctl start nginx.service
      for _ in $(seq 1 40); do
        curl -s -o /dev/null -m 2 http://127.0.0.1/health 2>/dev/null && break
        sleep 0.5
      done

      cat > /root/questions.txt <<'Q'
      The site is slow in a way that makes no sense. Most requests are instant.
      Some take six seconds. The origin is idle the whole time, and the requests
      that are slow have nothing in common except length.

      In front of the origin is a filter — /opt/waf/waf.py, started by
      `systemctl start waf`, configured by two files:

        /etc/waf/rules.conf   the rules, one per line: name, TAB, regex
        /etc/waf/waf.conf     budget_ms = 0

      nginx asks it about every request before proxying anything
      (`auth_request` in /etc/nginx/sites-enabled/edge), so the filter's latency
      is the site's latency. It answers one request at a time.

      Reproduce it:

        $ curl -s -o /dev/null -w '%{time_total}\n' http://127.0.0.1/health
        $ q=$(python3 -c 'print("1"*600)')
        $ curl -s -o /dev/null -w '%{time_total}\n' "http://127.0.0.1/asset.js?q=${q}x"

      The second one is not blocked. It is allowed — eventually. Watch what the
      filter says about it:

        $ journalctl -u waf -n 5 --no-pager

      Three things to do.

      1. Make that request fast again, and keep it allowed: it is not an attack
         and the answer is not to block it.

      2. Do not weaken the rule. /root/waf-corpus/block holds requests it must
         still refuse and /root/waf-corpus/allow holds requests it must still
         pass. The grader checks both.

      3. The next rule somebody writes will have the same defect. Bound it:
         waf.conf's budget_ms is the number of milliseconds a single rule is
         allowed to spend before the filter gives up on it and answers anyway.
         Pick one and set it. The grader will add its own pathological rule and
         expect the site to survive it.

      If the filter ever stops answering entirely, it is stuck inside a match:
      `systemctl restart waf` clears it.

      Then write /root/answers/waf.md, exactly two lines:

        failure_mode: <the name for what that regex does>
        budget_ms: <the number you set>
      Q

      echo "scenario ready — one rule, no budget, and a filter in front of everything"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      set -e
      pathological="/asset.js?q=$(python3 -c 'print("1"*600)')x"

      timed() {
        curl -sg -o /dev/null -m "$2" -w '%{http_code} %{time_total}' "http://127.0.0.1$1" 2>/dev/null || true
      }

      # ---- the site is up at all --------------------------------------------
      r=$(timed /health 10)
      if [ "${r%% *}" != "200" ]; then
        echo "not yet: http://127.0.0.1/health did not return 200 (got: $r)."
        if [ "${r%% *}" = "403" ]; then
          echo "         The filter is refusing ordinary traffic. A rule broad"
          echo "         enough to block /health blocks the site."
        else
          echo "         nginx and the filter both have to be running:"
          echo "         systemctl status nginx waf"
        fi
        exit 1
      fi

      # ---- the rule still means what it meant --------------------------------
      #
      # Checked before the timing, because a rule that blocks nothing is fast.
      while read -r uri; do
        [ -n "$uri" ] || continue
        r=$(timed "$uri" 15)
        if [ "${r%% *}" != "403" ]; then
          echo "not yet: $uri is no longer blocked (got: $r)."
          echo "         It is in /root/waf-corpus/block. A rule that stops"
          echo "         refusing these is not a faster rule, it is a deleted one."
          exit 1
        fi
      done < /root/waf-corpus/block

      while read -r uri; do
        [ -n "$uri" ] || continue
        r=$(timed "$uri" 15)
        if [ "${r%% *}" != "200" ]; then
          echo "not yet: $uri is being refused (got: $r)."
          echo "         It is in /root/waf-corpus/allow — ordinary traffic that"
          echo "         the rule must not touch."
          exit 1
        fi
      done < /root/waf-corpus/allow

      # ---- and it decides quickly ---------------------------------------------
      r=$(timed "$pathological" 20)
      code=${r%% *}
      secs=${r##* }
      if [ "$code" != "200" ]; then
        echo "not yet: the 600-character request came back $code, not 200."
        echo "         It is not an attack and it is not over budget — it is a"
        echo "         request the rule should decide about immediately and pass."
        case "$code" in
          500|503)
            echo "         That is the budget firing — the filter gave up on a rule"
            echo "         mid-match and nginx turned its answer into an error."
            echo "         A budget stops a slow rule from being an outage; it does"
            echo "         not make the rule fast. Both are needed."
            ;;
        esac
        exit 1
      fi
      if ! python3 -c "import sys; sys.exit(0 if float(sys.argv[1] or 99) < 2.0 else 1)" "$secs"; then
        echo "not yet: that request took ${secs}s. Under two seconds is the bar,"
        echo "         and a rule that does not backtrack answers in milliseconds."
        journalctl -u waf -n 3 --no-pager | sed 's/^/         /'
        exit 1
      fi

      # ---- one slow request is not allowed to be everybody's problem ----------
      #
      # Six of them at once against a filter that answers one at a time. If each
      # one is cheap this is unremarkable; if any of them is not, the seventh
      # request waits behind all six.
      for _ in $(seq 1 6); do
        curl -s -o /dev/null -m 25 "http://127.0.0.1$pathological" &
      done
      sleep 0.3
      r=$(timed /health 8)
      wait
      if [ "${r%% *}" != "200" ]; then
        echo "not yet: with six long requests in flight, /health returned $r."
        echo "         The filter answers one request at a time, so whatever a"
        echo "         single rule costs is paid by every request queued behind it."
        exit 1
      fi

      # ---- the next bad rule, which is not yours -------------------------------
      #
      # Tomorrow's deploy adds a rule with the same defect. Nothing about the
      # rewritten rule helps here: only a budget does.
      cp /etc/waf/rules.conf /tmp/rules.verify.bak
      python3 - <<'PY'
      rule = r"""(?:\"|'|\]|\}|\\|\d|(?:nan|infinity|true|false|null|undefined|symbol|math)|\+)+[)]*;?((?:\s|-|~|!|{}|\|\||\+)*.*(?:.*=.*))"""
      with open("/etc/waf/rules.conf", "a") as f:
          f.write("waf-verify-injected\t" + rule + "\n")
      PY
      r=$(timed "$pathological" 10)
      cp /tmp/rules.verify.bak /etc/waf/rules.conf
      rm -f /tmp/rules.verify.bak
      # The injected rule may have left a match in progress; a restart is the
      # only thing that takes the filter away from it.
      systemctl restart waf.service
      for _ in $(seq 1 40); do
        curl -s -m 2 http://127.0.0.1:8090/healthz 2>/dev/null | grep -q ok && break
        sleep 0.5
      done

      secs=${r##* }
      if [ "${r%% *}" = "000" ]; then
        echo "not yet: a rule with the same defect was added to /etc/waf/rules.conf"
        echo "         and the site stopped answering."
        echo "         budget_ms in /etc/waf/waf.conf is still $(sed -n 's/^[[:space:]]*budget_ms[[:space:]]*=[[:space:]]*//p' /etc/waf/waf.conf | head -1)."
        echo "         Rewriting one rule fixes one rule. A budget is what makes"
        echo "         the next one survivable."
        exit 1
      fi
      if ! python3 -c "import sys; sys.exit(0 if float(sys.argv[1] or 99) < 3.0 else 1)" "$secs"; then
        echo "not yet: with a pathological rule loaded, that request took ${secs}s."
        echo "         The budget has to be small enough that a rule cannot hold"
        echo "         a request open for seconds."
        exit 1
      fi

      # ---- naming it ------------------------------------------------------------
      if [ ! -s /root/answers/waf.md ]; then
        echo "not yet: /root/answers/waf.md is missing or empty."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < /root/answers/waf.md)
      mode=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*failure_mode[[:space:]]*[:=][[:space:]]*//p' | head -1)
      said=$(printf '%s\n' "$low" | sed -n 's/^[[:space:]]*budget_ms[[:space:]]*[:=][[:space:]]*\([0-9]*\).*/\1/p' | head -1)
      set_to=$(sed -n 's/^[[:space:]]*budget_ms[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' /etc/waf/waf.conf | head -1)

      if [ -z "$mode" ] || [ -z "$said" ]; then
        echo "not yet: /root/answers/waf.md needs a failure_mode line and a"
        echo "         budget_ms line."
        exit 1
      fi

      fail=0
      if ! printf '%s' "$mode" | grep -qE 'backtrack|redos'; then
        fail=1
        echo "not yet: you said failure_mode=$mode."
        echo "         The rule was not slow because the input was long. It was"
        echo "         slow because the engine had an exponential number of ways"
        echo "         to split that input between two adjacent .* and tried them."
        echo "         There is a name for that."
      fi

      if [ "$said" != "${set_to:-0}" ]; then
        fail=1
        echo "not yet: you said budget_ms=$said and /etc/waf/waf.conf says ${set_to:-nothing}."
        exit 1
      fi

      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the rule blocks what it blocked and decides in milliseconds,"
      echo "       and a rule that does not is cut off before it becomes an outage."
