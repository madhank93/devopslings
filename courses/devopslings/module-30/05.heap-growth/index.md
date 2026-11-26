---
kind: lesson
title: "RSS only ever goes up"
description: |
  session-cache grows all day and never gives memory back, and the plan of
  record is a nightly restart. The growth is anonymous memory, not page
  cache, so something allocates and never frees. memleak watches every
  allocation in the live process and reports the ones still outstanding, by
  the stack that made them. Find that stack and fix it, then prove it on the
  same process.
name: heap-growth
slug: heap-growth
createdAt: "2026-11-22"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      systemctl stop session-cache.service 2>/dev/null || true
      systemctl reset-failed session-cache.service 2>/dev/null || true
      rm -rf /usr/local/src/session-cache /usr/local/bin/session-cache \
             /etc/systemd/system/session-cache.service /etc/systemd/system/session-cache.service.d \
             /root/answers/heap.txt
      id sessions >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin sessions
      install -d /root/answers /usr/local/src/session-cache

      cat > /usr/local/src/session-cache/session-cache.c <<'C'
      /* session-cache: answers session lookups from an in-memory table. */
      #include <ctype.h>
      #include <stdio.h>
      #include <stdlib.h>
      #include <string.h>
      #include <time.h>
      #include <unistd.h>

      #define SLOTS 4096
      #define USERS 3000
      #define STATS "/run/session-cache/stats"

      struct entry {
          char *key;
          char token[48];
      };

      static struct entry table[SLOTS];
      static unsigned long served, hits;

      static char *normalize_key(const char *raw)
      {
          char *key = strdup(raw);
          for (char *p = key; *p; p++)
              *p = tolower((unsigned char)*p);
          return key;
      }

      static unsigned slot(const char *key)
      {
          unsigned h = 2166136261u;
          for (; *key; key++)
              h = (h ^ (unsigned char)*key) * 16777619u;
          return h % SLOTS;
      }

      static const char *lookup(const char *raw)
      {
          char *key = normalize_key(raw);
          struct entry *e = &table[slot(key)];
          served++;
          if (e->key && strcmp(e->key, key) == 0) {
              hits++;
              return e->token;
          }
          free(e->key);
          e->key = key;
          snprintf(e->token, sizeof e->token, "tok-%08lx", (unsigned long)random());
          return e->token;
      }

      static void write_stats(void)
      {
          FILE *f = fopen(STATS ".tmp", "w");
          if (!f)
              return;
          fprintf(f, "served=%lu\nhits=%lu\n", served, hits);
          fclose(f);
          rename(STATS ".tmp", STATS);
      }

      int main(void)
      {
          char raw[96];
          struct timespec next;
          clock_gettime(CLOCK_MONOTONIC, &next);
          for (unsigned long tick = 0;; tick++) {
              for (int i = 0; i < 50; i++) {
                  snprintf(raw, sizeof raw, "Session:EU-West:User-%05ld:Web-Checkout",
                           random() % USERS);
                  lookup(raw);
              }
              if (tick % 100 == 0)
                  write_stats();
              next.tv_nsec += 10 * 1000 * 1000;
              if (next.tv_nsec >= 1000000000L) {
                  next.tv_sec++;
                  next.tv_nsec -= 1000000000L;
              }
              clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
          }
      }
      C
      cat > /usr/local/src/session-cache/Makefile <<'MK'
      session-cache: session-cache.c
      	gcc -O0 -g -fno-omit-frame-pointer -Wall -o $@ $<

      install: session-cache
      	install -m 0755 session-cache /usr/local/bin/session-cache
      MK
      make -s -C /usr/local/src/session-cache install

      cat > /etc/systemd/system/session-cache.service <<'UNIT'
      [Unit]
      Description=Session lookup cache

      [Service]
      User=sessions
      RuntimeDirectory=session-cache
      ExecStart=/usr/local/bin/session-cache
      Restart=on-failure
      UNIT
      systemctl daemon-reload
      systemctl start session-cache.service
      sleep 5
      pid=$(systemctl show -p MainPID --value session-cache.service)

      echo "scenario ready — session-cache.service (PID $pid) serves 5000 lookups a second from a"
      echo "table of 3000 sessions. $(grep RssAnon /proc/$pid/status | tr -s ' \t' ' ') and climbing."
      echo "Write your findings to /root/answers/heap.txt."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      ans=/root/answers/heap.txt
      site=$({ grep -iE '^allocation_site=' "$ans" 2>/dev/null || true; } | tail -1 | cut -d= -f2- | tr -d ' "()')
      case "$site" in
        "")
          echo "not yet: $ans needs allocation_site=<function>: the function in session-cache.c whose"
          echo "         allocations memleak reports as outstanding and growing."
          exit 1 ;;
        strdup|malloc|*__libc*|calloc|realloc|__strdup)
          echo "not yet: allocation_site=$site is the allocator; every allocation goes through it. memleak"
          echo "         prints the whole stack: the site is the first frame in session-cache.c."
          exit 1 ;;
        lookup|main)
          echo "not yet: allocation_site=$site is further down the stack: it calls the function that"
          echo "         allocates. Name the frame that called the allocator."
          exit 1 ;;
        normalize_key) ;;
        *)
          echo "not yet: allocation_site=$site. memleak -p <pid> prints outstanding allocations grouped by"
          echo "         stack, largest last; read the frame above the allocator."
          exit 1 ;;
      esac

      if ! systemctl is-active -q session-cache.service; then
        echo "not yet: session-cache.service is not running."
        exit 1
      fi
      pid=$(systemctl show -p MainPID --value session-cache.service)
      tasks=$(ls /proc/$pid/task | wc -l)
      kids=$(pgrep -c -P "$pid" || true)
      if [ "$tasks" != 1 ] || [ "$kids" != 0 ]; then
        echo "not yet: session-cache now runs $tasks threads and $kids child processes. Recycling workers"
        echo "         hides a leak the way a restart does; the one process has to stop growing."
        exit 1
      fi
      stat() { awk -F= -v k="$1" '$1 == k { print $2 }' /run/session-cache/stats 2>/dev/null || true; }
      rss() { awk '/^RssAnon:/ { print $2 }' /proc/$pid/status 2>/dev/null || true; }
      sleep 2
      s0=$(stat served); r0=$(rss)
      sleep 20
      s1=$(stat served); r1=$(rss)
      now=$(systemctl show -p MainPID --value session-cache.service)
      if [ "$now" != "$pid" ] || [ -z "$r1" ]; then
        echo "not yet: session-cache was restarted during a 20 s soak (PID $pid, then $now). A restart"
        echo "         gives the memory back and keeps leaking; the soak needs the same process throughout."
        exit 1
      fi
      if [ -z "$s0" ] || [ -z "$s1" ] || [ "$s1" -le "$s0" ]; then
        echo "not yet: the served counter did not move forward during the soak (${s0:-?} then ${s1:-?}): the"
        echo "         process restarted its work, or stopped doing it."
        exit 1
      fi
      rate=$(( (s1 - s0) / 20 ))
      echo "this check soaked PID $pid for 20 s: ${rate} lookups/s, RssAnon ${r0} kB -> ${r1} kB"
      if [ "$rate" -lt 4000 ]; then
        echo "not yet: ${rate} lookups a second, against 5000 before. Doing less work leaks less slowly."
        exit 1
      fi
      if [ $(( r1 - r0 )) -gt 512 ]; then
        echo "not yet: anonymous memory grew $(( r1 - r0 )) kB in 20 s on the same process. The leak is"
        echo "         still there; memleak shows which allocations are still outstanding."
        exit 1
      fi
      echo "PASS — normalize_key()'s copy was never freed on a cache hit; PID $pid now holds flat at"
      echo "       ${r1} kB of anonymous memory over 20 s at ${rate} lookups a second."
---
