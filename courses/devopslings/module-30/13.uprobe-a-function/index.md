---
kind: lesson
title: "one function is slow, and the next deploy window is Thursday"
description: |
  The pricing service is slow and everyone suspects price_lookup(). The usual
  move — add timing logs and redeploy — needs a change window and moves the
  very timing it is trying to see. A uprobe times the function inside the
  running process, without a restart. The work is measuring price_lookup alone,
  not the request around it.
name: uprobe-a-function
slug: uprobe-a-function
createdAt: "2026-11-23"

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
      systemctl stop pricer.service 2>/dev/null || true
      systemctl reset-failed pricer.service 2>/dev/null || true
      rm -rf /opt/pricer /var/lib/pricer /etc/systemd/system/pricer.service \
             /root/uprobe.bt /root/answers/latency.md
      install -d /root/answers /opt/pricer /var/lib/pricer
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

      # ---- the service ---------------------------------------------------
      # C, not Go: a uretprobe rewrites the return address on the stack, and
      # Go's movable goroutine stacks can crash under one.
      # parse_order costs 9 ms, so timing the whole request lands in a
      # different power-of-two bucket than price_lookup alone, whatever the
      # delay.
      cat > /opt/pricer/pricer.c <<'C'
      #include <stdio.h>
      #include <unistd.h>

      static long tuning_us(void) {
          long d = 0;
          FILE *f = fopen("/var/lib/pricer/tuning", "r");
          if (f) { if (fscanf(f, "%ld", &d) != 1) d = 0; fclose(f); }
          return d;
      }

      __attribute__((noinline)) int parse_order(int id) {
          usleep(9000);
          return id % 97;
      }

      __attribute__((noinline)) long price_lookup(int sku) {
          usleep(tuning_us());
          return (long)sku * 13;
      }

      __attribute__((noinline)) int format_reply(long price, char *buf, int n) {
          usleep(700);
          return snprintf(buf, n, "{\"price\":%ld}", price);
      }

      __attribute__((noinline)) int handle_request(int id) {
          char buf[64];
          return format_reply(price_lookup(parse_order(id)), buf, sizeof buf);
      }

      int main(void) {
          for (int i = 0;; i++) {
              handle_request(i);
              usleep(20000);
          }
      }
      C
      gcc -O1 -g -o /opt/pricer/pricer /opt/pricer/pricer.c
      python3 -c 'import random; print(random.choice([3000, 6000, 12000, 24000]))' \
        > /var/lib/pricer/tuning

      cat > /etc/systemd/system/pricer.service <<'U'
      [Unit]
      Description=Pricing service

      [Service]
      ExecStart=/opt/pricer/pricer
      U
      systemctl daemon-reload
      systemctl start pricer.service
      sleep 1
      pid=$(systemctl show -P MainPID pricer.service)
      # Identity of the running process: a restart changes both.
      printf '%s %s\n' "$pid" "$(awk '{print $22}' "/proc/$pid/stat")" > /var/lib/pricer/.identity
      chmod 0600 /var/lib/pricer/.identity

      echo "scenario ready — pricer.service is running as PID $pid; price_lookup() is suspected"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      set -e
      w=/root/uprobe.bt
      ans=/root/answers/latency.md
      tuning=/var/lib/pricer/tuning
      mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

      read -r pid0 start0 < /var/lib/pricer/.identity
      pid=$(systemctl show -P MainPID pricer.service)
      start=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null || true)
      if [ "$pid" != "$pid0" ] || [ "$start" != "$start0" ]; then
        echo "not yet: pricer is not the process that was running at the start (PID"
        echo "         $pid0). It was restarted or replaced — which is the change window"
        echo "         this lesson is about avoiding. Reset the lesson and probe the"
        echo "         running process instead."
        exit 1
      fi

      if [ ! -s "$w" ]; then
        echo "not yet: $w is missing or empty. Write a bpftrace program that prints"
        echo "         a histogram of price_lookup()'s latency."
        exit 1
      fi
      if [ ! -s "$ans" ]; then
        echo "not yet: $ans is missing or empty:  latency-ms: <number>"
        exit 1
      fi
      a=$(sed -n 's/^[[:space:]]*latency-ms[[:space:]]*[:=][[:space:]]*//p' "$ans" | head -n 1 | grep -oE '[0-9]+(\.[0-9]+)?' | head -n 1 || true)
      d=$(cat "$tuning")
      if [ -z "$a" ] || ! python3 -c "import sys; a=float(sys.argv[1]); d=float(sys.argv[2])/1000; sys.exit(0 if abs(a-d) <= d*0.25+0.5 else 1)" "$a" "$d"; then
        echo "not yet: latency-ms says '${a:-nothing}', and price_lookup() does not take"
        echo "         that long. Time it from uprobe to uretprobe, per thread, and read"
        echo "         where the histogram's mass sits."
        exit 1
      fi

      # ---- re-run the probe with a delay the student has not seen ---------
      new=$(python3 -c "import random,sys; print(random.choice([v for v in [3000,6000,12000,24000] if v != int(sys.argv[1])]))" "$d")
      echo "$new" > "$tuning"
      trap 'echo "$d" > "$tuning"' EXIT
      sleep 1
      out=$(mktemp)
      bpftrace "$w" > "$out" 2>&1 &
      bt=$!
      for _ in $(seq 120); do
        grep -q '^Attaching' "$out" && break
        kill -0 "$bt" 2>/dev/null || break
        sleep 0.5
      done
      if ! kill -0 "$bt" 2>/dev/null; then
        echo "not yet: bpftrace stopped running $w. Its output:"
        tail -n 8 "$out" | sed 's/^/         /'
        rm -f "$out"; exit 1
      fi
      sleep 4
      kill -INT "$bt" 2>/dev/null || true
      wait "$bt" 2>/dev/null || true

      # The fullest bucket across every histogram printed, and whether the new
      # delay falls in it read as ns, us or ms.
      verdict=$(python3 - "$out" "$new" <<'PY'
      import re, sys
      units = {"": 1, "K": 1024, "M": 1024**2, "G": 1024**3}
      best = None
      for line in open(sys.argv[1], errors="replace"):
          m = re.match(r"^\[(\d+)([KMG]?),\s*(\d+)([KMG]?)\)\s+(\d+)\s*\|", line.strip())
          if m:
              lo = int(m.group(1)) * units[m.group(2)]
              hi = int(m.group(3)) * units[m.group(4)]
              n = int(m.group(5))
              if best is None or n > best[2]:
                  best = (lo, hi, n)
      if best is None:
          print("nohist")
      else:
          us = int(sys.argv[2])
          ok = any(best[0] <= v < best[1] for v in (us * 1000, us, us / 1000))
          print("ok" if ok else "off %d %d" % best[:2])
      PY
      )
      tail_out=$(tail -n 12 "$out")
      rm -f "$out"
      case "$verdict" in
        ok) ;;
        nohist)
          echo "not yet: $w printed no histogram while price_lookup() ran. Use hist()"
          echo "         on the time between the uprobe and the uretprobe. Its output:"
          printf '%s\n' "$tail_out" | sed 's/^/         /'
          exit 1 ;;
        *)
          echo "not yet: the grader changed price_lookup()'s delay to $((new / 1000)) ms and"
          echo "         re-ran $w; its fullest bucket is [$(echo "$verdict" | cut -d' ' -f2),"
          echo "         $(echo "$verdict" | cut -d' ' -f3)), which does not hold that delay in"
          echo "         ns, us or ms. If you timed handle_request() or the whole loop,"
          echo "         you measured parsing and formatting too."
          exit 1 ;;
      esac

      echo "PASS — the uprobe follows price_lookup() to a delay it had not seen, and"
      echo "       pricer is still PID $pid0, never restarted."
