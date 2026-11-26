---
kind: lesson
title: "one parcel, and the pricing service dies every second"
description: |
  tariffd restarts every second and the queue behind it has stopped. systemd
  brings it back each time, so every crash leaves nothing behind but a restart
  counter. Make the next crash leave a core, read the backtrace out of it with
  gdb, and fix the line it names, so the same input no longer kills it.
name: core-dump-postmortem
slug: core-dump-postmortem
createdAt: "2026-11-22"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      systemctl stop tariffd.service 2>/dev/null || true
      systemctl reset-failed tariffd.service 2>/dev/null || true
      rm -rf /usr/local/src/tariffd /var/spool/tariffd /var/lib/tariffd /usr/local/bin/tariffd \
             /etc/systemd/system/tariffd.service /etc/systemd/system/tariffd.service.d \
             /root/answers/core.txt
      id tariffd >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin tariffd
      install -d /root/answers /var/lib/devopslings /usr/local/src/tariffd
      install -d -o tariffd -g tariffd /var/lib/tariffd /var/spool/tariffd \
                 /var/spool/tariffd/inbox /var/spool/tariffd/done

      # core_pattern belongs to the host kernel, not to this box. Record it so
      # the check can tell if it was changed.
      cat /proc/sys/kernel/core_pattern > /var/lib/devopslings/core_pattern

      cat > /usr/local/src/tariffd/tariffd.c <<'C'
      /* tariffd: prices parcel requests dropped into the inbox. */
      #include <dirent.h>
      #include <stdio.h>
      #include <stdlib.h>
      #include <string.h>
      #include <unistd.h>

      #define INBOX "/var/spool/tariffd/inbox"
      #define DONE "/var/spool/tariffd/done"

      struct request {
          char id[32];
          char *region;
          long grams;
      };

      static char *field(char *buf, const char *key)
      {
          size_t k = strlen(key);
          for (char *line = strtok(buf, "\n"); line; line = strtok(NULL, "\n"))
              if (strncmp(line, key, k) == 0 && line[k] == '=')
                  return strdup(line + k + 1);
          return NULL;
      }

      static long region_rate(const char *region)
      {
          size_t n = strlen(region);
          long rate = 40;
          for (size_t i = 0; i < n; i++)
              rate += region[i] % 7;
          return rate;
      }

      static int parse(const char *path, struct request *r)
      {
          char buf[1024], copy[1024];
          FILE *f = fopen(path, "r");
          if (!f)
              return -1;
          size_t len = fread(buf, 1, sizeof buf - 1, f);
          fclose(f);
          buf[len] = '\0';

          char *v;
          memcpy(copy, buf, len + 1);
          v = field(copy, "id");
          snprintf(r->id, sizeof r->id, "%s", v ? v : "?");
          free(v);
          memcpy(copy, buf, len + 1);
          r->region = field(copy, "region");
          memcpy(copy, buf, len + 1);
          v = field(copy, "grams");
          r->grams = v ? atol(v) : 0;
          free(v);
          return 0;
      }

      static void price(const char *name)
      {
          char in[512], out[512];
          struct request r;
          snprintf(in, sizeof in, "%s/%s", INBOX, name);
          snprintf(out, sizeof out, "%s/%s.out", DONE, name);
          if (parse(in, &r) != 0)
              return;
          long cents = region_rate(r.region) * (r.grams / 100 + 1);
          FILE *f = fopen(out, "w");
          if (f) {
              fprintf(f, "id=%s\ncents=%ld\n", r.id, cents);
              fclose(f);
          }
          free(r.region);
          unlink(in);
      }

      int main(void)
      {
          setvbuf(stdout, NULL, _IOLBF, 0);
          printf("tariffd ready\n");
          for (;;) {
              struct dirent **names;
              int n = scandir(INBOX, &names, NULL, alphasort);
              for (int i = 0; i < n; i++) {
                  if (names[i]->d_name[0] != '.')
                      price(names[i]->d_name);
                  free(names[i]);
              }
              if (n >= 0)
                  free(names);
              sleep(1);
          }
      }
      C
      cat > /usr/local/src/tariffd/Makefile <<'MK'
      tariffd: tariffd.c
      	gcc -g -O0 -Wall -o $@ $<

      install: tariffd
      	install -m 0755 tariffd /usr/local/bin/tariffd
      MK
      make -s -C /usr/local/src/tariffd install
      grep -n 'size_t n = strlen(region);' /usr/local/src/tariffd/tariffd.c | cut -d: -f1 \
        > /var/lib/devopslings/core-dump.line

      printf 'id=Q-1043\ngrams=2300\n' > /var/lib/devopslings/q-1043.req
      printf 'id=Q-1050\nregion=EU-WEST\ngrams=800\n' > /var/lib/devopslings/q-1050.req
      for i in 1041 1042 1044; do
        printf 'id=Q-%s\nregion=EU-WEST\ngrams=%s\n' "$i" "$((i - 900))" > /var/spool/tariffd/inbox/q-$i.req
      done
      cp /var/lib/devopslings/q-1043.req /var/spool/tariffd/inbox/q-1043.req
      chown tariffd:tariffd /var/spool/tariffd/inbox/*

      cat > /etc/systemd/system/tariffd.service <<'UNIT'
      [Unit]
      Description=Parcel tariff pricing
      StartLimitIntervalSec=0

      [Service]
      User=tariffd
      WorkingDirectory=/var/lib/tariffd
      ExecStart=/usr/local/bin/tariffd
      Restart=always
      RestartSec=1
      UNIT
      systemctl daemon-reload
      systemctl start tariffd.service

      for _ in $(seq 1 30); do
        [ "$(systemctl show -p NRestarts --value tariffd.service)" -ge 2 ] && break
        sleep 1
      done
      [ "$(systemctl show -p NRestarts --value tariffd.service)" -ge 2 ]

      echo "scenario ready — tariffd.service restarts every second; q-1044 has been waiting since."
      echo "The source is in /usr/local/src/tariffd (make install rebuilds it)."
      echo "Write your findings to /root/answers/core.txt."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      ans=/root/answers/core.txt
      field() { { grep -iE "^$1=" "$ans" 2>/dev/null || true; } | tail -1 | cut -d= -f2- | tr -d ' "'; }

      if [ "$(cat /proc/sys/kernel/core_pattern)" != "$(cat /var/lib/devopslings/core_pattern)" ]; then
        echo "not yet: kernel.core_pattern has changed. It is one setting for the whole host, and every"
        echo "         other container on it now sends its cores where you pointed this one's. Set it back"
        echo "         to: $(cat /var/lib/devopslings/core_pattern)"
        exit 1
      fi

      core=$(field core); fn=$(field function); ln=$(field line)
      if [ -z "$core" ] || [ -z "$fn" ] || [ -z "$ln" ]; then
        echo "not yet: $ans needs core=<path to a core file>, function= and line= for the frame in"
        echo "         tariffd.c where it crashed, from gdb's backtrace of that core."
        exit 1
      fi
      if [ ! -f "$core" ]; then
        echo "not yet: core=$core does not exist. A crashing service writes no core while its core size"
        echo "         limit is 0, and systemd's default for a service is 0."
        exit 1
      fi
      if ! file -b "$core" | grep -q 'core file' || ! file -b "$core" | grep -q tariffd; then
        echo "not yet: core=$core is not a core file from tariffd ($(file -b "$core" | cut -c1-60))."
        exit 1
      fi
      case "$fn" in
        *strlen*|*memchr*|__*|libc*|'??')
          echo "not yet: function=$fn is frame #0, inside the C library. libc did what it was asked; the"
          echo "         bug is in the first frame that belongs to tariffd.c, the one that called it."
          exit 1 ;;
        price|main|parse|field)
          echo "not yet: function=$fn is in the backtrace, but not where it faulted. Take the frame closest"
          echo "         to #0 that is in tariffd.c."
          exit 1 ;;
        region_rate) ;;
        *)
          echo "not yet: function=$fn. Load the core with gdb /usr/local/bin/tariffd <core> and run bt."
          exit 1 ;;
      esac
      if [ "$ln" != "$(cat /var/lib/devopslings/core-dump.line)" ]; then
        echo "not yet: line=$ln. gdb prints the line as tariffd.c:<n> on region_rate's frame."
        exit 1
      fi

      # The binary itself must survive the input, so a unit that clears the
      # request before starting cannot stand in for a fix.
      systemctl stop tariffd.service
      rm -f /var/spool/tariffd/inbox/* /var/spool/tariffd/done/q-1043*
      install -o tariffd -g tariffd -m 0644 /var/lib/devopslings/q-1043.req /var/spool/tariffd/inbox/q-1043.req
      rc=0
      ( cd /var/lib/tariffd && timeout 3 setpriv --reuid tariffd --regid tariffd --clear-groups \
          /usr/local/bin/tariffd >/dev/null 2>&1 ) 2>/dev/null || rc=$?
      if [ "$rc" != 124 ]; then
        echo "not yet: /usr/local/bin/tariffd, run by itself with Q-1043 queued, exits with status $rc"
        echo "         instead of staying up. Keeping the request away from the service hides the crash;"
        echo "         the program has to handle a request with no region= line."
        exit 1
      fi

      # Replay the input that crashed it, behind and ahead of a normal one.
      systemctl reset-failed tariffd.service 2>/dev/null || true
      rm -f /var/spool/tariffd/inbox/* /var/spool/tariffd/done/q-1043* /var/spool/tariffd/done/q-1050*
      install -o tariffd -g tariffd -m 0644 /var/lib/devopslings/q-1043.req /var/spool/tariffd/inbox/q-1043.req
      install -o tariffd -g tariffd -m 0644 /var/lib/devopslings/q-1050.req /var/spool/tariffd/inbox/q-1050.req
      systemctl start tariffd.service
      pid=$(systemctl show -p MainPID --value tariffd.service)
      for _ in $(seq 1 10); do
        [ -f /var/spool/tariffd/done/q-1050.req.out ] && [ ! -e /var/spool/tariffd/inbox/q-1043.req ] && break
        sleep 0.5
      done
      sleep 1
      now=$(systemctl show -p MainPID --value tariffd.service)
      if [ "$now" != "$pid" ] || [ "$pid" = 0 ]; then
        echo "not yet: tariffd crashed again on Q-1043, the request with no region= line."
        echo "         The core shows what it did with the missing value; tariffd has to handle it."
        exit 1
      fi
      if [ ! -f /var/spool/tariffd/done/q-1050.req.out ]; then
        echo "not yet: tariffd is up but did not price Q-1050, a normal request queued after Q-1043."
        exit 1
      fi
      if [ -e /var/spool/tariffd/inbox/q-1043.req ]; then
        echo "not yet: tariffd survives Q-1043 by leaving it in the inbox, where it is retried every"
        echo "         second for ever. Price it or reject it, and take it out of the inbox."
        exit 1
      fi
      echo "PASS — region_rate() called strlen() on the missing region at tariffd.c:$ln; tariffd now"
      echo "       handles Q-1043 and keeps the queue moving, PID $pid throughout."
---
