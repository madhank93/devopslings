---
kind: lesson
title: "70% system time, and nothing hot in the code"
description: |
  The settlement spooler burns most of a core, and almost all of it is system
  time. Its own profile is flat: no function in it is doing anything
  expensive. The proposal is a kernel sysctl. Profile with kernel stacks
  instead, and the kernel says exactly what it is being asked to do, a million
  times a second.
name: perf-top-system-time
slug: perf-top-system-time
createdAt: "2026-11-22"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 120
    run: |
      systemctl stop spooler.service 2>/dev/null || true
      systemctl reset-failed spooler.service 2>/dev/null || true
      rm -rf /usr/local/src/spooler /var/spool/spooler /usr/local/bin/spooler \
             /etc/systemd/system/spooler.service /root/answers/systime.txt
      id spooler >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin spooler
      install -d /root/answers /var/lib/devopslings /usr/local/src/spooler
      install -d -o spooler -g spooler /var/spool/spooler

      cat > /usr/local/src/spooler/spooler.c <<'C'
      /* spooler: streams settlement records to the spool file at a fixed rate. */
      #include <fcntl.h>
      #include <stdio.h>
      #include <string.h>
      #include <time.h>
      #include <unistd.h>

      #define OUT "/var/spool/spooler/stream.log"
      #define BYTES_PER_TICK 10000 /* every 10 ms: 1 MB/s */
      #define ROTATE_AT (64L << 20)

      static int fd;
      static long written;

      static void put(const char *s, size_t n)
      {
          for (size_t i = 0; i < n; i++)
              write(fd, s + i, 1);
          written += n;
      }

      static size_t emit(unsigned long seq)
      {
          char line[128];
          int n = snprintf(line, sizeof line,
                           "rec %010lu region=EU-WEST cents=%06lu status=settled\n",
                           seq, (seq * 7919) % 1000000);
          put(line, n);
          return n;
      }

      int main(void)
      {
          fd = open(OUT, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, 0644);
          if (fd < 0)
              return 1;
          unsigned long seq = 0;
          struct timespec next;
          clock_gettime(CLOCK_MONOTONIC, &next);
          for (;;) {
              size_t tick = 0;
              while (tick < BYTES_PER_TICK)
                  tick += emit(seq++);
              if (written >= ROTATE_AT) {
                  ftruncate(fd, 0);
                  written = 0;
              }
              next.tv_nsec += 10 * 1000 * 1000;
              if (next.tv_nsec >= 1000000000L) {
                  next.tv_sec++;
                  next.tv_nsec -= 1000000000L;
              }
              clock_nanosleep(CLOCK_MONOTONIC, TIMER_ABSTIME, &next, NULL);
          }
      }
      C
      cat > /usr/local/src/spooler/Makefile <<'MK'
      spooler: spooler.c
      	gcc -O0 -g -fno-omit-frame-pointer -Wall -o $@ $<

      install: spooler
      	install -m 0755 spooler /usr/local/bin/spooler
      MK
      make -s -C /usr/local/src/spooler install

      cat > /etc/systemd/system/spooler.service <<'UNIT'
      [Unit]
      Description=Settlement record spooler

      [Service]
      User=spooler
      ExecStart=/usr/local/bin/spooler
      Restart=on-failure
      UNIT
      systemctl daemon-reload
      systemctl start spooler.service
      sleep 1

      # The before figure is measured here, on this machine: system time per
      # megabyte written depends on the CPU and the kernel.
      pid=$(systemctl show -p MainPID --value spooler.service)
      s0=$(awk '{print $15}' /proc/$pid/stat); w0=$(awk '/^wchar/ {print $2}' /proc/$pid/io)
      sleep 3
      s1=$(awk '{print $15}' /proc/$pid/stat); w1=$(awk '/^wchar/ {print $2}' /proc/$pid/io)
      awk -v s=$((s1 - s0)) -v w=$((w1 - w0)) 'BEGIN { printf "%.2f\n", s / (w / 1048576) }' \
        > /var/lib/devopslings/systime.baseline
      echo "$(( (w1 - w0) / 3 ))" > /var/lib/devopslings/systime.rate

      echo "scenario ready — spooler.service streams settlement records to /var/spool/spooler/stream.log"
      echo "at $(( (w1 - w0) / 3 / 1024 )) KiB/s, spending $(( (s1 - s0) / 3 ))% of a CPU in the kernel to do it."
      echo "Write your findings to /root/answers/systime.txt."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      ans=/root/answers/systime.txt
      field() { { grep -iE "^$1=" "$ans" 2>/dev/null || true; } | tail -1 | cut -d= -f2- | tr -d ' "'; }
      sc=$(field syscall); bpc=$(field bytes_per_call)
      if [ -z "$sc" ] || [ -z "$bpc" ]; then
        echo "not yet: $ans needs syscall=<name> and bytes_per_call=<n>: the system call the kernel"
        echo "         time is spent in, from perf with kernel stacks, and how much each call moves."
        exit 1
      fi
      case "$sc" in
        write|__arm64_sys_write|__x64_sys_write|ksys_write|sys_write) ;;
        clock_nanosleep|nanosleep|*sleep*)
          echo "not yet: syscall=$sc. The spooler sleeps between ticks, and sleeping costs no CPU; the"
          echo "         system time is in the call under the deepest, widest kernel stack."
          exit 1 ;;
        *)
          echo "not yet: syscall=$sc. Record with call graphs (perf record -g -e cpu-clock -p <pid>) and"
          echo "         look for the sys_ entry point at the base of the kernel frames."
          exit 1 ;;
      esac
      if [ "$bpc" != 1 ]; then
        echo "not yet: bytes_per_call=$bpc. /proc/<pid>/io counts bytes written (wchar) and write calls"
        echo "         (syscw); divide one by the other, or watch a few calls in strace -p."
        exit 1
      fi

      pid=$(systemctl show -p MainPID --value spooler.service)
      if [ -z "$pid" ] || [ "$pid" = 0 ]; then
        echo "not yet: spooler.service is not running."
        exit 1
      fi
      s0=$(awk '{print $15}' /proc/$pid/stat); w0=$(awk '/^wchar/ {print $2}' /proc/$pid/io)
      sleep 3
      s1=$(awk '{print $15}' /proc/$pid/stat 2>/dev/null || echo "$s0")
      w1=$(awk '/^wchar/ {print $2}' /proc/$pid/io 2>/dev/null || echo "$w0")
      rate=$(( (w1 - w0) / 3 )); want=$(cat /var/lib/devopslings/systime.rate)
      base=$(cat /var/lib/devopslings/systime.baseline)
      now=$(awk -v s=$((s1 - s0)) -v w=$((w1 - w0)) 'BEGIN { if (w == 0) print "inf"; else printf "%.2f", s / (w / 1048576) }')
      echo "this check measured 3 s: ${rate} B/s written, ${now} ticks of system time per MiB (before: ${base})"
      if [ "$rate" -lt $(( want * 9 / 10 )) ]; then
        echo "not yet: spooler now writes ${rate} B/s against ${want} before. Writing less, or more slowly,"
        echo "         lowers system time without changing what each byte costs."
        exit 1
      fi
      if ! awk -v n="$now" -v b="$base" 'BEGIN { exit !(n * 10 <= b) }'; then
        echo "not yet: ${now} ticks of system time per MiB against ${base} before; it should be at most a"
        echo "         tenth. Each write() costs a trip into the kernel whatever its size."
        exit 1
      fi
      # Right after a rotation the file is nearly empty; give it a second.
      lines=$(tail -n 200 /var/spool/spooler/stream.log | sed '1d;$d')
      if [ "$(wc -l <<<"$lines")" -lt 20 ]; then
        sleep 1
        lines=$(tail -n 200 /var/spool/spooler/stream.log | sed '1d;$d')
      fi
      if ! grep -qE '^rec [0-9]{10} region=EU-WEST cents=[0-9]{6} status=settled$' <<<"$lines" ||
         grep -vqE '^rec [0-9]{10} region=EU-WEST cents=[0-9]{6} status=settled$' <<<"$lines"; then
        echo "not yet: /var/spool/spooler/stream.log no longer holds whole records, one per line:"
        tail -n 3 /var/spool/spooler/stream.log
        exit 1
      fi
      if ! awk '{ n = $2 + 0; if (NR > 1 && n != p + 1) exit 1; p = n }' <<<"$lines"; then
        echo "not yet: records in /var/spool/spooler/stream.log are out of sequence or missing."
        exit 1
      fi
      echo "PASS — one-byte write() calls were the system time; the spooler now spends ${now} ticks"
      echo "       per MiB in the kernel against ${base}, at the same rate and with the same records."
---
