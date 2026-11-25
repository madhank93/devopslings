---
kind: lesson
title: "900 ms requests from a service at 5% CPU"
description: |
  quotes answers in anything up to 900 ms and barely uses the CPU. An on-CPU
  profile of it is a flame graph of nothing, because the slow requests are not
  working — they are waiting. Off-CPU tracing records where threads block and
  for how long. The work is finding what the requests wait on and changing the code
  so they stop waiting, without stopping the work that made them wait.
name: off-cpu-time
slug: off-cpu-time
createdAt: "2026-11-23"
timingSensitive: true

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      set -e

      # ---- clean slate ---------------------------------------------------
      systemctl stop quotes.service rates-feed.service 2>/dev/null || true
      systemctl reset-failed quotes.service rates-feed.service 2>/dev/null || true
      rm -rf /opt/quotes /opt/rates-feed /etc/systemd/system/quotes.service \
             /etc/systemd/system/rates-feed.service /root/answers/offcpu.md
      install -d /root/answers /opt/quotes /opt/rates-feed
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

      # ---- the upstream: a rates feed that takes 900 ms per fetch ---------
      # It stands in for a remote service. It is not yours to change.
      cat > /opt/rates-feed/feed.py <<'PY'
      import http.server, time
      served = 0
      class H(http.server.BaseHTTPRequestHandler):
          def do_GET(self):
              global served
              if self.path == "/served":
                  body = ("%d\n" % served).encode()
              else:
                  time.sleep(0.9)
                  served += 1
                  body = b"EURUSD=1.0841\n"
              self.send_response(200)
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)
          def log_message(self, *a):
              pass
      http.server.ThreadingHTTPServer(("127.0.0.1", 8099), H).serve_forever()
      PY
      cat > /etc/systemd/system/rates-feed.service <<'U'
      [Unit]
      Description=Rates feed (remote, stand-in)

      [Service]
      ExecStart=/usr/bin/python3 /opt/rates-feed/feed.py
      U

      # ---- the service -----------------------------------------------------
      # Frame pointers on, so off-CPU stacks can walk the user stack into main code.
      cat > /opt/quotes/Makefile <<'MK'
      .RECIPEPREFIX = >
      quotes: quotes.c
      > gcc -O0 -g -fno-omit-frame-pointer -pthread -o quotes quotes.c
      MK
      cat > /opt/quotes/quotes.c <<'C'
      #define _GNU_SOURCE
      #include <arpa/inet.h>
      #include <pthread.h>
      #include <stdio.h>
      #include <string.h>
      #include <unistd.h>

      static pthread_mutex_t rates_lock = PTHREAD_MUTEX_INITIALIZER;
      static char rates[128] = "EURUSD=unknown\n";
      static long version;

      /* Fetches the current rates from the feed into buf. Slow: a network round
       * trip to a service that takes most of a second. */
      __attribute__((noinline)) static int fetch_rates(char *buf, int n) {
          int s = socket(AF_INET, SOCK_STREAM, 0);
          struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(8099) };
          inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
          if (connect(s, (struct sockaddr *)&a, sizeof a) < 0) { close(s); return -1; }
          const char *req = "GET /rates HTTP/1.0\r\n\r\n";
          write(s, req, strlen(req));
          char resp[512]; int got = 0, r;
          while ((r = read(s, resp + got, sizeof resp - 1 - got)) > 0) got += r;
          close(s);
          resp[got] = 0;
          char *body = strstr(resp, "\r\n\r\n");
          if (!body) return -1;
          snprintf(buf, n, "%s", body + 4);
          return 0;
      }

      __attribute__((noinline)) static void *refresh_rates(void *arg) {
          (void)arg;
          pthread_setname_np(pthread_self(), "rates-refresh");
          for (;;) {
              pthread_mutex_lock(&rates_lock);
              fetch_rates(rates, sizeof rates);
              version++;
              pthread_mutex_unlock(&rates_lock);
              usleep(50000);
          }
          return NULL;
      }

      __attribute__((noinline)) static void handle_quote(int c) {
          char body[160], out[256];
          pthread_mutex_lock(&rates_lock);
          snprintf(body, sizeof body, "version=%ld %s", version, rates);
          pthread_mutex_unlock(&rates_lock);
          int n = snprintf(out, sizeof out,
              "HTTP/1.0 200 OK\r\nContent-Length: %zu\r\n\r\n%s", strlen(body), body);
          write(c, out, n);
      }

      int main(void) {
          pthread_t t;
          pthread_create(&t, NULL, refresh_rates, NULL);
          int s = socket(AF_INET, SOCK_STREAM, 0), one = 1;
          setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
          struct sockaddr_in a = { .sin_family = AF_INET, .sin_port = htons(8096) };
          inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
          bind(s, (struct sockaddr *)&a, sizeof a);
          listen(s, 64);
          for (;;) {
              int c = accept(s, NULL, NULL);
              if (c < 0) continue;
              char req[1024];
              read(c, req, sizeof req);
              handle_quote(c);
              close(c);
          }
      }
      C
      make -s -C /opt/quotes
      cat > /etc/systemd/system/quotes.service <<'U'
      [Unit]
      Description=Quotes API
      After=rates-feed.service

      [Service]
      ExecStart=/opt/quotes/quotes
      U
      systemctl daemon-reload
      systemctl start rates-feed.service
      sleep 1
      systemctl start quotes.service
      install -d /var/lib/devopslings
      sha256sum /opt/rates-feed/feed.py /etc/systemd/system/rates-feed.service \
        > /var/lib/devopslings/rates-feed.sha256

      cat > /root/questions.txt <<'Q'
      quotes (127.0.0.1:8096, source in /opt/quotes) answers in up to 900 ms and
      uses about 5% of a CPU. Find where its requests spend their time while they
      are not running, and fix the code so they stop waiting. The rates it serves
      must keep refreshing from rates-feed as before; rates-feed is a remote
      service and not yours to change.

      Rebuild with:  make -C /opt/quotes && systemctl restart quotes

      Write /root/answers/offcpu.md:
        waits-on: <what a request blocks on, and who holds it>
      Q

      echo "scenario ready — quotes takes up to 900 ms at 5% CPU"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      set -e
      ans=/root/answers/offcpu.md
      budget_ms=300

      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty:  waits-on: <...>"
        exit 1
      fi
      w=$(tr 'A-Z' 'a-z' < "$ans" | sed -n 's/^[[:space:]]*waits-on[[:space:]]*[:=][[:space:]]*//p' | head -n 1)
      if ! printf '%s' "$w" | grep -Eq '\b(rates_lock|mutex|lock)\b'; then
        echo "not yet: waits-on says '${w:-nothing}'. an off-CPU trace (Hint 1) shows"
        echo "         each blocked stack and how long it was off; the request thread's"
        echo "         stack runs from handle_quote into the call that blocks."
        exit 1
      fi
      if ! printf '%s' "$w" | grep -Eq 'refresh|fetch|feed'; then
        echo "not yet: waits-on names the lock but not who holds it so long. Look at"
        echo "         the other thread's off-CPU stack too."
        exit 1
      fi

      if ! sha256sum -c --quiet /var/lib/devopslings/rates-feed.sha256 >/dev/null 2>&1; then
        echo "not yet: rates-feed was changed. It stands in for a remote service;"
        echo "         the fix belongs in quotes."
        exit 1
      fi
      systemctl is-active -q rates-feed.service || systemctl start rates-feed.service
      if ! systemctl is-active -q quotes.service; then
        echo "not yet: quotes is not running. Rebuild and restart it:"
        echo "         make -C /opt/quotes && systemctl restart quotes"
        exit 1
      fi
      sleep 1

      res=$(python3 - <<'PY'
      import re, time, urllib.request
      lat, versions = [], []
      feed0 = int(urllib.request.urlopen("http://127.0.0.1:8099/served").read())
      end = time.time() + 5
      while time.time() < end:
          t = time.time()
          try:
              body = urllib.request.urlopen("http://127.0.0.1:8096/", timeout=5).read().decode()
          except Exception:
              print("down"); raise SystemExit
          lat.append((time.time() - t) * 1000)
          m = re.search(r"version=(\d+)", body)
          versions.append(int(m.group(1)) if m else -1)
          time.sleep(0.05)
      feed1 = int(urllib.request.urlopen("http://127.0.0.1:8099/served").read())
      print("%d %d %d %d" % (max(lat), len(set(versions)), feed1 - feed0,
                             -1 in versions))
      PY
      )
      if [ "$res" = down ]; then
        echo "not yet: quotes stopped answering on 127.0.0.1:8096 while being timed."
        exit 1
      fi
      read -r slowest distinct fetched badbody <<EOF
      $res
      EOF
      if [ "$badbody" = 1 ]; then
        echo "not yet: quotes' response lost its 'version=N <rates>' body. Keep the"
        echo "         response as it was."
        exit 1
      fi
      # The slowest request, not the median: a longer pause between refreshes
      # makes most requests fast while every fetch still blocks the ones behind it.
      if [ "$slowest" -gt "$budget_ms" ]; then
        echo "not yet: quotes' slowest request took ${slowest} ms (budget ${budget_ms} ms)."
        echo "         Requests still wait for the lock while the refresher holds it across"
        echo "         a 900 ms fetch. Fetch first, then take the lock only to swap the"
        echo "         result in."
        exit 1
      fi

      if [ "$fetched" -lt 3 ] || [ "$distinct" -lt 3 ]; then
        echo "not yet: the rates barely refresh — rates-feed served $fetched fetches in"
        echo "         5 s and quotes returned $distinct distinct versions. Fewer refreshes,"
        echo "         or none, remove the wait and the fresh data with it; keep fetching"
        echo "         as often, just not while holding the lock requests need."
        exit 1
      fi
      # Requests must still synchronise with the refresher: dropping the lock
      # from handle_quote also removes the wait, by racing the copy. Requests
      # run on the main thread (tid == pid), so count that thread's lock calls.
      pid=$(systemctl show -P MainPID quotes.service)
      libc=$(awk '/libc\.so\.6$/ {print $6; exit}' "/proc/$pid/maps")
      lockout=$(mktemp)
      timeout -s INT 15 bpftrace -e "
        BEGIN { printf(\"ready\\n\"); }
        uprobe:$libc:pthread_mutex_lock,
        uprobe:$libc:pthread_rwlock_rdlock,
        uprobe:$libc:pthread_spin_lock
        /pid == $pid && tid == $pid/ { @n = count(); }" > "$lockout" 2>&1 &
      bt=$!
      # BEGIN fires once every probe is attached; "Attaching" prints before that.
      for _ in $(seq 60); do
        grep -q '^ready' "$lockout" && break
        kill -0 "$bt" 2>/dev/null || break
        sleep 0.25
      done
      for _ in 1 2 3 4 5; do curl -s -o /dev/null --max-time 2 http://127.0.0.1:8096/ || true; done
      kill -INT "$bt" 2>/dev/null || true
      wait "$bt" 2>/dev/null || true
      locks=$(sed -n 's/^@n: *//p' "$lockout")
      rm -f "$lockout"
      if [ "${locks:-0}" -lt 1 ]; then
        echo "not yet: handle_quote no longer takes a lock before reading rates, while"
        echo "         the refresh thread writes them. That removes the wait by racing"
        echo "         the copy. Keep the lock in handle_quote; take it out of the fetch."
        exit 1
      fi

      echo "PASS — quotes' slowest request took ${slowest} ms, and the rates still refresh ($distinct versions"
      echo "       in 5 s). The fetch no longer runs under the lock requests need."
