---
kind: lesson
title: "the deploy never goes healthy, and the reason moves"
description: |
  ./deploy.sh fails with "container api is unhealthy". That is the whole ticket,
  every run, because the fault is drawn at random from five this module taught:
  a memory limit under the cache, a health check with no warm-up grace, a
  published port used from inside the network, a volume the non-root user cannot
  write, and a build context missing a file. The drill is the ladder: ps,
  inspect, logs, exec, image.
name: container-triage-drill
slug: container-triage-drill
createdAt: "2026-09-29"

sandbox:
  stack: none
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e
      proj=devopslings-container-triage

      docker compose -p "$proj" down -v --rmi local --remove-orphans >/dev/null 2>&1 || true
      rm -rf .drill answers
      mkdir -p .drill answers

      cat > app.py <<'PY'
      """Catalogue API. Joins the product catalogue with live quotes from the quotes service."""
      import http.server
      import json
      import os
      import socketserver
      import threading
      import time
      import urllib.request

      WARMUP = int(os.environ.get("WARMUP_SECONDS", "12"))
      CACHE_MB = int(os.environ.get("CACHE_MB", "160"))
      QUOTES = os.environ.get("QUOTES_URL", "http://quotes:8000")
      READY = False

      print(f"api starting as uid {os.getuid()}", flush=True)

      with open("catalog.json") as f:
          CATALOG = json.load(f)

      with open("/data/state.json", "w") as f:
          json.dump({"started": time.time(), "uid": os.getuid()}, f)

      CACHE = b"\x01" * (CACHE_MB * 1024 * 1024)
      print(f"price cache {CACHE_MB}MB resident, warming for {WARMUP}s", flush=True)


      def warm():
          global READY
          time.sleep(WARMUP)
          READY = True
          print("price cache warm", flush=True)


      def quote():
          with urllib.request.urlopen(QUOTES + "/quote", timeout=2) as r:
              return json.load(r)


      class Handler(http.server.BaseHTTPRequestHandler):
          def reply(self, code, body):
              payload = (body if isinstance(body, str) else json.dumps(body) + "\n").encode()
              self.send_response(code)
              self.send_header("Content-Length", str(len(payload)))
              self.end_headers()
              self.wfile.write(payload)

          def do_GET(self):
              if self.path == "/health":
                  return self.reply(200, "alive\n")
              if self.path == "/stats":
                  return self.reply(200, {"uid": os.getuid(), "cache_mb": len(CACHE) // 1048576,
                                          "warmup": WARMUP, "quotes_url": QUOTES})
              if not READY:
                  return self.reply(503, "warming: price cache not loaded\n")
              try:
                  q = quote()
              except Exception as e:
                  return self.reply(503, f"quotes unreachable at {QUOTES}: {e}\n")
              if self.path == "/ready":
                  return self.reply(200, "ready\n")
              if self.path == "/quote":
                  return self.reply(200, {"sku": CATALOG[0]["sku"], "eur": q["eur"]})
              self.reply(404, "not found\n")

          def log_message(self, *args):
              pass


      socketserver.ThreadingTCPServer.allow_reuse_address = True
      with socketserver.ThreadingTCPServer(("", 8000), Handler) as httpd:
          threading.Thread(target=warm, daemon=True).start()
          httpd.serve_forever()
      PY

      cat > quotes.py <<'PY'
      """Quotes service. Serves the last FX snapshot; the eu-west feed is decommissioned."""
      import http.server
      import json
      import socketserver


      def complain():
          print("ERROR feed eu-west: connect timeout after 5000ms, serving last snapshot", flush=True)


      class Handler(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              complain()
              payload = (json.dumps({"eur": "1.0842"}) + "\n").encode()
              self.send_response(200)
              self.send_header("Content-Length", str(len(payload)))
              self.end_headers()
              self.wfile.write(payload)

          def log_message(self, *args):
              pass


      complain()
      socketserver.ThreadingTCPServer.allow_reuse_address = True
      with socketserver.ThreadingTCPServer(("", 8000), Handler) as httpd:
          httpd.serve_forever()
      PY

      printf '[{"sku": "EUR-FWD-30", "name": "30 day forward"}]\n' > catalog.json

      cat > deploy.sh <<'SH'
      #!/bin/sh
      set -e
      docker compose -p devopslings-container-triage up -d --build --wait --wait-timeout 90
      curl -fsS http://localhost:18094/quote
      SH
      chmod +x deploy.sh

      # ---- seed one fault ----------------------------------------------------
      #
      # Every candidate ends the same way from the outside ("container api is
      # unhealthy"), and each leaves its evidence on a different rung.
      faults="oom warmup dns uid context"
      n=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
      fault=$(echo "$faults" | cut -d' ' -f$(( n % 5 + 1 )))

      mem=256m
      quotes_url=http://quotes:8000
      start_period="      start_period: 30s"
      data_dir=" && install -d -o app -g app /data"
      ignore_json=""
      case "$fault" in
        oom)     mem=128m ;;                            # the cache alone is 160MB
        warmup)  start_period="" ;;                     # 3 x 2s of 503 before a 12s warm-up ends
        dns)     quotes_url=http://localhost:18095 ;;   # the host's port, from inside the network
        uid)     data_dir="" ;;                         # the volume mount point is created root-owned
        context) ignore_json="*.json" ;;                # catalog.json never reaches the image
      esac

      cat > Dockerfile <<DOCKER
      FROM python:3.12-slim
      RUN useradd --uid 10001 --create-home app${data_dir}
      WORKDIR /app
      COPY . .
      USER app
      CMD ["python3", "app.py"]
      DOCKER

      printf '.git\n*.log\nanswers/\n.drill/\n%s\n' "$ignore_json" > .dockerignore

      cat > compose.yaml <<YAML
      services:
        quotes:
          build: .
          command: ["python3", "quotes.py"]
          ports:
            - "18095:8000"

        api:
          build: .
          restart: unless-stopped
          depends_on: [quotes]
          mem_limit: ${mem}
          memswap_limit: ${mem}
          environment:
            QUOTES_URL: ${quotes_url}
          ports:
            - "18094:8000"
          volumes:
            - state:/data
          healthcheck:
            test: ["CMD", "python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8000/ready', timeout=2)"]
            interval: 2s
            timeout: 3s
            retries: 3
      ${start_period}

      volumes:
        state:
      YAML

      # The digest, not the name: obfuscation, not a secret. The real gate is
      # that the deploy has to go healthy without any of the sidesteps.
      printf '%s' "$fault" | sha256sum | awk '{print $1}' > .drill/state
      sha256sum app.py quotes.py catalog.json > .drill/files

      echo "scenario ready — files are in $(pwd)"
      echo
      echo "The ticket:"
      echo "  ./deploy.sh"
      echo "  ... container devopslings-container-triage-api-1 is unhealthy"
      echo
      echo "Write what you find to answers/triage.md (cause:, evidence:, detection:)."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 600
    run: |
      proj=devopslings-container-triage

      digest=$(cat .drill/state 2>/dev/null || true)
      fault=""
      for cand in oom warmup dns uid context; do
        h=$(printf '%s' "$cand" | sha256sum | awk '{print $1}')
        [ "$h" = "$digest" ] && fault="$cand"
      done
      if [ -z "$fault" ]; then
        echo "not yet: .drill/state does not name a seeded fault. Start the lesson"
        echo "         again — the scenario has to seed one before it can be graded."
        exit 1
      fi

      for f in compose.yaml Dockerfile app.py quotes.py catalog.json; do
        if [ ! -f "$f" ]; then
          echo "not yet: no $f in $(pwd)"
          exit 1
        fi
      done

      # ---- the symptom ------------------------------------------------------
      # From an empty volume every time: ownership of a named volume is decided
      # the first time something mounts it, so a leftover volume proves nothing.
      docker compose -p "$proj" down -v --remove-orphans >/dev/null 2>&1 || true
      if ! out=$(docker compose -p "$proj" up -d --build --wait --wait-timeout 90 2>&1); then
        echo "not yet: the deploy still does not go healthy:"
        printf '%s\n' "$out" | tail -3 | sed 's/^/    /'
        cid=$(docker compose -p "$proj" ps -aq api 2>/dev/null | head -1)
        if [ -n "$cid" ]; then
          echo "         api right now: $(docker inspect -f 'status={{.State.Status}} restarts={{.RestartCount}} exit={{.State.ExitCode}}' "$cid" 2>/dev/null)"
        fi
        echo "         Walk it down: ps, then inspect (.State, .State.Health), then"
        echo "         logs, then curl the app's own /ready, then exec, then the image."
        exit 1
      fi

      body=$(curl -fsS -m 5 http://localhost:18094/quote 2>/dev/null || true)
      case "$body" in
        *EUR-FWD-30*1.0842*) ;;
        *)
          echo "not yet: api is healthy and GET localhost:18094/quote answers '${body:-nothing}'."
          echo "         It should join the catalogue with a live quote."
          exit 1
          ;;
      esac

      cid=$(docker compose -p "$proj" ps -q api | head -1)
      qid=$(docker compose -p "$proj" ps -q quotes | head -1)

      # ---- the red herring --------------------------------------------------
      sums=$(sha256sum -c .drill/files 2>/dev/null || true)
      qlogs=$(docker logs "$qid" 2>&1 || true)
      case "$sums" in *"quotes.py: OK"*) herring=ok ;; *) herring=changed ;; esac
      if [ "$herring" != ok ]; then
        echo "not yet: quotes.py has been changed. Its ERROR line about the eu-west feed"
        echo "         has been there for months and it serves every quote regardless —"
        echo "         a loud log line is not a cause until something depends on it."
        exit 1
      fi
      case "$qlogs" in *"ERROR feed eu-west"*) ;; *) qid="" ;; esac
      if [ -z "$qid" ]; then
        echo "not yet: the quotes service is not running quotes.py as shipped. It was"
        echo "         never the fault; put it back the way it was."
        exit 1
      fi

      # ---- the sidesteps ----------------------------------------------------
      changed=$(printf '%s\n' "$sums" | grep -v ': OK$' | cut -d: -f1 | tr '\n' ' ' || true)
      if [ -n "$changed" ]; then
        echo "not yet: these files have been edited: $changed"
        echo "         The application is not what broke. Repair how it is built and run."
        exit 1
      fi

      stats=$(curl -fsS -m 5 http://localhost:18094/stats 2>/dev/null || true)
      field() { printf '%s' "$stats" | sed -n "s/.*\"$1\": \"*\([^,\"}]*\).*/\1/p"; }
      uid=$(field uid); cache=$(field cache_mb); warm=$(field warmup); qurl=$(field quotes_url)

      if [ -z "$uid" ] || [ "$uid" = "0" ]; then
        echo "not yet: api runs as uid '${uid:-unknown}'. Running as root makes a volume"
        echo "         permission error go away and throws out the non-root requirement."
        exit 1
      fi
      if [ "$cache" != "160" ] || [ "$warm" != "12" ]; then
        echo "not yet: api reports a ${cache:-?}MB cache and a ${warm:-?}s warm-up; it ships"
        echo "         with 160MB and 12s. Shrinking what the app does to fit the"
        echo "         container is the container's problem moved into the app."
        exit 1
      fi

      mem=$(docker inspect -f '{{.HostConfig.Memory}}' "$cid")
      if [ "${mem:-0}" -le 0 ] || [ "$mem" -gt 536870912 ]; then
        echo "not yet: api's memory limit is $(( ${mem:-0} / 1048576 ))MB (0 = none). It needs one,"
        echo "         and the node budget for it is 512MB at most."
        exit 1
      fi

      net=$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$cid")
      if [ "$net" = "host" ] || [ "$qurl" != "http://quotes:8000" ]; then
        echo "not yet: api reaches quotes at '${qurl:-?}' (network mode $net)."
        echo "         Inside the compose network the service name and the container"
        echo "         port are the address: http://quotes:8000. A route through the"
        echo "         host's published port works on one laptop."
        exit 1
      fi

      hc=$(docker inspect -f '{{if .Config.Healthcheck}}{{json .Config.Healthcheck.Test}}{{end}}' "$cid")
      hc_ok=no
      case "$hc" in *NONE*) ;; */ready*) hc_ok=yes ;; esac
      window=$(docker inspect -f '{{if .Config.Healthcheck}}{{printf "%d %d" .Config.Healthcheck.Interval .Config.Healthcheck.Retries}}{{end}}' "$cid" \
        | awk '{i = $1 ? $1 : 30e9; r = $2 ? $2 : 3; print int(i * r / 1e9)}')
      if [ "$hc_ok" != yes ]; then
        echo "not yet: api's health check runs ${hc:-nothing}."
        echo "         It has to be the app's readiness endpoint, /ready — /health says"
        echo "         the process is alive, not that it can serve."
        exit 1
      fi
      if [ "$window" -gt 10 ]; then
        echo "not yet: interval x retries is ${window}s, so a container that dies takes"
        echo "         that long to be marked unhealthy. Grace for startup is what"
        echo "         start_period is for; it does not slow down detection afterwards."
        exit 1
      fi

      mounts=$(docker inspect -f '{{range .Mounts}}{{.Type}}:{{.Destination}} {{end}}' "$cid")
      case " $mounts" in
        *" volume:/data "*) ;;
        *)
          echo "not yet: api has no named volume at /data (mounts: ${mounts:-none})."
          echo "         The state volume is the thing under repair."
          exit 1
          ;;
      esac
      case "$mounts" in
        *bind:*)
          echo "not yet: api has bind mounts ($mounts). What it needs has to be in the"
          echo "         image, or it will not be there on any other host."
          exit 1
          ;;
      esac
      if ! docker exec "$cid" test -f /app/catalog.json; then
        echo "not yet: /app/catalog.json is not in the image."
        exit 1
      fi

      perms=$(docker exec "$cid" stat -c '%u %a %n' /data /data/state.json 2>/dev/null || true)
      loose=$(printf '%s\n' "$perms" | awk '$2 ~ /[2367]$/' || true)
      if [ -n "$loose" ]; then
        echo "not yet: world-writable on the volume:"
        printf '%s\n' "$loose" | sed 's/^/    /'
        echo "         Give it to uid $uid instead of to everyone."
        exit 1
      fi
      notmine=$(printf '%s\n' "$perms" | awk -v u="$uid" 'NF && $1 != u' || true)
      if [ -z "$perms" ] || [ -n "$notmine" ]; then
        echo "not yet: api runs as $uid and these belong to someone else (uid, mode, path):"
        printf '%s\n' "${notmine:-could not stat /data}" | sed 's/^/    /'
        exit 1
      fi

      # ---- naming it ----------------------------------------------------------
      if [ ! -s answers/triage.md ]; then
        echo "not yet: answers/triage.md is missing or empty. The deploy is healthy;"
        echo "         now say what it was: cause:, evidence:, detection: lines."
        exit 1
      fi

      low=$(tr 'A-Z' 'a-z' < answers/triage.md)
      line() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | head -1; }
      cause=$(line cause); evidence=$(line evidence); detection=$(line detection)

      c_oom='\b(oom|oomkilled|oom-?kill(ed|er)?|out of memory|memory limit|mem_limit|memswap_limit|137)\b'
      c_warmup='\b(start_?period|start period|warm-?up|warming|startup)\b'
      c_dns='\b(localhost|published port|service name|dns|127\.0\.0\.1|18095|quotes_url)\b'
      c_uid='\b(uid|permission|permissions|owner|owned|ownership|chown|non-?root|root-owned|10001)\b'
      c_context='\b(dockerignore|build context|context|catalog\.json)\b'

      case "$fault" in
        oom)
          want_c=$c_oom
          want_e='\b(oomkilled|oom|137|restartcount|restarts|memory\.events|docker events|docker stats)\b'
          want_d='\b(oom|oomkilled|oom_kill|restarts?|restartcount|137|memory)\b' ;;
        warmup)
          want_c=$c_warmup
          want_e='\b(health|healthcheck|\.state\.health|503|warming|ready|unhealthy)\b'
          want_d='\b(time.to.healthy|unhealthy|health|startup|deploy|rollout)\b' ;;
        dns)
          want_c=$c_dns
          want_e='\b(quotes_url|getent|nslookup|ready|refused|exec|stats|environment|env)\b'
          want_d='\b(dependency|upstream|quotes|readiness|ready|5xx|503|error rate|unhealthy|refused)\b' ;;
        uid)
          want_c=$c_uid
          want_e='\b(permission denied|permissionerror|errno 13|stat|ls|id|logs)\b'
          want_d='\b(restarts?|restartcount|crash(loop)?|permission|write errors?|eacces|exit)\b' ;;
        context)
          want_c=$c_context
          want_e='\b(filenotfounderror|no such file|errno 2|ls|docker run|image|logs)\b'
          want_d='\b(restarts?|restartcount|crash(loop)?|smoke|exit|startup|image)\b' ;;
      esac

      hits=0
      for re in "$c_oom" "$c_warmup" "$c_dns" "$c_uid" "$c_context"; do
        printf '%s' "$cause" | grep -Eq "$re" && hits=$((hits + 1))
      done

      fail=0
      if [ -z "$cause" ]; then
        fail=1; echo "not yet: no cause: line in answers/triage.md."
      elif [ "$hits" -ge 3 ]; then
        fail=1; echo "not yet: the cause line names several different mechanisms. Name the one."
      elif ! printf '%s' "$cause" | grep -Eq "$want_c"; then
        fail=1
        echo "not yet: the deploy is healthy, so something was repaired, and your cause"
        echo "         line does not name it. The seeded fault was: $fault."
      fi
      if [ -z "$evidence" ]; then
        fail=1; echo "not yet: no evidence: line — the command or field that proved it."
      elif ! printf '%s' "$evidence" | grep -Eq "$want_e"; then
        fail=1
        echo "not yet: the evidence line does not name something that shows a $fault fault"
        echo "         — which command, and which field or line in its output?"
      fi
      if [ -z "$detection" ]; then
        fail=1; echo "not yet: no detection: line — a signal and a threshold that pages first."
      elif ! printf '%s' "$detection" | grep -Eq "$want_d" || ! printf '%s' "$detection" | grep -q '[0-9]'; then
        fail=1
        echo "not yet: the detection line needs a signal that moves for a $fault fault"
        echo "         and a number to alert at."
      fi
      [ "$fail" -eq 0 ] || exit 1

      docker compose -p "$proj" down -v --rmi local --remove-orphans >/dev/null 2>&1 || true
      echo "PASS — the seeded fault ($fault) was repaired where it lives: non-root, a"
      echo "       bounded memory limit, a readiness check that detects fast, quotes by"
      echo "       service name, everything in the image. Stack, volume and images removed."
---
