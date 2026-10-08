---
kind: lesson
title: "orders cannot take an order, and the box will not say why"
description: |
  POST /orders fails on box. That is the whole ticket, every time — because the
  fault is drawn at random from five, each a different way one Linux box stops
  a service writing: space held by a deleted file, inodes gone, a config typo,
  a descriptor limit, a directory the service cannot write. The drill is the
  order you ask the box questions in.
name: box-triage-drill
slug: box-triage-drill
createdAt: "2026-09-29"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      set -e

      # ---- clean slate -------------------------------------------------
      systemctl stop orders.service orders-export.service 2>/dev/null || true
      systemctl reset-failed orders.service orders-export.service 2>/dev/null || true
      rm -rf /etc/systemd/system/orders.service.d \
             /etc/systemd/system/orders-export.service /usr/local/bin/orders-export
      pkill -KILL -u orders 2>/dev/null || true
      fuser -km /srv/orders >/dev/null 2>&1 || true
      umount /srv/orders 2>/dev/null || true
      rm -rf /srv/orders /etc/orders /opt/orders /var/lib/drill /root/answers/triage.md
      id orders >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin orders
      install -d /opt/orders /etc/orders /srv/orders /var/lib/drill /root/answers

      # The service's own filesystem: small in bytes and in inodes, so either
      # can run out in seconds without touching anything else on the box.
      mount -t tmpfs -o size=48m,nr_inodes=4000,mode=0755 tmpfs /srv/orders
      install -d -o orders -g orders -m 0755 /srv/orders/ledger /srv/orders/log
      install -d -o orders -g orders -m 2770 /srv/orders/spool
      for i in $(seq -w 1 40); do
        printf 'sku=B-%s&qty=1\n' "$i" > "/srv/orders/spool/ORD-seed-$i.order"
      done
      chown orders:orders /srv/orders/spool/*.order

      # The red herring: yesterday's log, rotated, large and full of errors
      # that were retried and resolved. Nothing holds it open.
      python3 - <<'PY'
      import random
      random.seed(7)
      with open("/srv/orders/log/orders.log.1", "w") as f:
          n = 0
          while f.tell() < 12 * 1024 * 1024:
              n += 1
              h, m, s = (n // 3600) % 24, (n // 60) % 60, n % 60
              if n % 9 == 0:
                  f.write(f"2026-09-28T{h:02d}:{m:02d}:{s:02d} ERROR payments upstream timeout "
                          f"after 5000ms, retry {n % 3 + 1}/3 for ORD-{100000 + n}\n")
              else:
                  f.write(f"2026-09-28T{h:02d}:{m:02d}:{s:02d} accepted ORD-{100000 + n} "
                          f"sku=A-{random.randint(100, 999)} qty={random.randint(1, 5)}\n")
      PY
      chown orders:orders /srv/orders/log/orders.log.1
      touch -d '-2 hours' /srv/orders/log/orders.log.1
      sha256sum /srv/orders/log/orders.log.1 | awk '{print $1}' > /var/lib/drill/herring

      cat > /etc/orders/orders.conf <<'CONF'
      # orders service. Read once, at start.
      port = 8088
      spool = /srv/orders/spool
      log = /srv/orders/log/orders.log
      CONF

      cat > /opt/orders/orders.py <<'PY'
      import http.server
      import os
      import time

      CONF = "/etc/orders/orders.conf"


      def conf():
          out = {}
          with open(CONF) as fh:
              for line in fh:
                  line = line.strip()
                  if line and not line.startswith("#") and "=" in line:
                      k, v = line.split("=", 1)
                      out[k.strip()] = v.strip()
          return out


      c = conf()
      PORT = int(c["port"])
      SPOOL = c["spool"]
      LOG = c["log"]

      # One append handle per ledger shard, held for the life of the process.
      SHARDS = [open(f"/srv/orders/ledger/shard-{i:02d}.log", "a") for i in range(32)]


      class Orders(http.server.BaseHTTPRequestHandler):
          def reply(self, code, body):
              body = body.encode()
              self.send_response(code)
              self.send_header("Content-Type", "text/plain")
              self.send_header("Content-Length", str(len(body)))
              self.end_headers()
              self.wfile.write(body)

          def do_GET(self):
              # Liveness only: the process is up. It says nothing about writes.
              self.reply(200, "ok\n")

          def do_POST(self):
              n = int(self.headers.get("Content-Length") or 0)
              body = self.rfile.read(n)
              oid = f"ORD-{time.time_ns()}"
              try:
                  with open(os.path.join(SPOOL, oid + ".order"), "wb") as f:
                      f.write(body + b"\n")
                  with open(LOG, "a") as f:
                      f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} accepted {oid}\n")
                  shard = SHARDS[hash(oid) % len(SHARDS)]
                  shard.write(oid + "\n")
                  shard.flush()
              except OSError as e:
                  print(f"orders: {oid} not stored: {e}", flush=True)
                  self.reply(500, "order not stored\n")
                  return
              self.reply(200, f"order accepted {oid}\n")

          def log_message(self, *args):
              pass


      http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Orders).serve_forever()
      PY

      cat > /etc/systemd/system/orders.service <<'UNIT'
      [Unit]
      Description=orders API
      After=network.target
      StartLimitIntervalSec=30
      StartLimitBurst=3

      [Service]
      User=orders
      Group=orders
      ExecStart=/usr/bin/python3 /opt/orders/orders.py
      Restart=on-failure
      RestartSec=1

      [Install]
      WantedBy=multi-user.target
      UNIT

      systemctl daemon-reload
      systemctl enable --now orders.service >/dev/null 2>&1

      probe() {
        curl -sS -m 5 -X POST --data 'sku=A-100&qty=1' http://127.0.0.1:8088/orders 2>/dev/null | grep -q 'order accepted'
      }

      # Everything works at this point. Prove it before breaking one thing, so a
      # scenario that failed to come up cannot be mistaken for the seeded fault.
      ok=""
      for _ in $(seq 1 40); do
        if probe; then ok=yes; break; fi
        sleep 0.25
      done
      if [ -z "$ok" ]; then
        echo "the scenario did not come up healthy before the fault was seeded"
        exit 1
      fi
      sha256sum /opt/orders/orders.py | awk '{print $1}' > /var/lib/drill/program

      # ---- seed one fault --------------------------------------------------
      faults="disk inodes config nofile perms"
      n=$(od -An -N2 -tu2 < /dev/urandom | tr -d ' ')
      fault=$(echo "$faults" | cut -d' ' -f$(( n % 5 + 1 )))

      case "$fault" in
        disk)
          # A resident exporter that fills its scratch file, unlinks it "to tidy
          # up", and keeps the descriptor. du cannot see the space; df can.
          cat > /usr/local/bin/orders-export <<'PY2'
      #!/usr/bin/env python3
      import os, time

      SCRATCH = "/srv/orders/log/export.tmp"
      fd = os.open(SCRATCH, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o640)
      chunk = b"x" * (1024 * 1024)
      try:
          while True:
              os.write(fd, chunk)
      except OSError:
          pass
      os.unlink(SCRATCH)
      while True:
          time.sleep(3600)
      PY2
          chmod 0755 /usr/local/bin/orders-export
          printf '[Unit]\nDescription=orders nightly export\n\n[Service]\nUser=orders\nExecStart=/usr/local/bin/orders-export\nRestart=always\nRestartSec=2\n\n[Install]\nWantedBy=multi-user.target\n' \
            > /etc/systemd/system/orders-export.service
          systemctl daemon-reload
          systemctl enable --now orders-export.service >/dev/null 2>&1
          for _ in $(seq 1 40); do
            [ "$(df --output=avail -k /srv/orders | tail -1 | tr -dc '0-9')" -lt 64 ] && break
            sleep 0.25
          done
          ;;
        inodes)
          # An aborted bulk import left one empty part file per record. Almost no
          # bytes; every inode on the filesystem.
          install -d -o orders -g orders -m 0750 /srv/orders/spool/.incoming
          runuser -u orders -- python3 -c '
      import os
      i = 0
      while True:
          try:
              open(f"/srv/orders/spool/.incoming/import-{i:05d}.part", "w").close()
          except OSError:
              break
          i += 1
      '
          ;;
        config)
          # A letter O where a zero belongs. The unit restarts, fails the same way
          # three times, and systemd stops trying.
          sed -i 's/^port = 8088$/port = 8O88/' /etc/orders/orders.conf
          systemctl restart orders.service >/dev/null 2>&1 || true
          ;;
        nofile)
          # A hardening drop-in with a descriptor limit one above what the idle
          # service already holds: it starts, accepts, and cannot open the spool
          # file for any order.
          pid=$(systemctl show -p MainPID --value orders.service)
          held=$(ls /proc/"$pid"/fd | wc -l)
          install -d /etc/systemd/system/orders.service.d
          printf '# Security review: least privilege for orders.\n[Service]\nNoNewPrivileges=yes\nLimitNOFILE=%s\n' \
            "$(( held + 1 ))" > /etc/systemd/system/orders.service.d/10-hardening.conf
          systemctl daemon-reload
          systemctl restart orders.service
          for _ in $(seq 1 40); do
            curl -s -m 1 http://127.0.0.1:8088/ >/dev/null 2>&1 && break
            sleep 0.25
          done
          ;;
        perms)
          # Restored from a backup taken as root: the spool directory came back
          # root-owned and 0755, and the service runs as orders.
          chown root:root /srv/orders/spool
          chmod 0755 /srv/orders/spool
          ;;
      esac

      if probe; then
        echo "the $fault fault was seeded and orders still takes writes"
        exit 1
      fi

      # The digest, not the name: obfuscation, not a secret. The real gate is
      # that orders takes writes again, repaired at the cause.
      printf '%s' "$fault" | sha256sum | awk '{print $1}' > /var/lib/drill/state
      chmod 600 /var/lib/drill/state /var/lib/drill/herring /var/lib/drill/program

      cat > /root/questions.txt <<'Q'
      orders cannot take an order:

        curl -sS -m 5 -X POST --data 'sku=A-100&qty=1' http://127.0.0.1:8088/orders

      It should print "order accepted ORD-...". Everything worked a moment ago,
      and exactly one thing was then broken — drawn at random from five.

      orders.service runs /opt/orders/orders.py as the user orders, reads
      /etc/orders/orders.conf, and writes to /srv/orders (its own filesystem):
      one file per order in spool/, a line in log/orders.log, a line in a
      ledger shard.

      1. Make orders take writes again by repairing what was broken, where it
         was broken. Not around it: the service stays a systemd unit running
         as orders, the program and its config paths stay as they are, and
         /srv/orders stays the filesystem it is.

      2. Write /root/answers/triage.md, three lines:

           cause:     <what was wrong, in a few words>
           evidence:  <the command or number that proved it>
           detection: <a signal and a threshold that would have paged first>

      Run it again and the fault moves. The drill is the order of the
      questions, not the answer.
      Q

      echo "scenario ready — one fault seeded, POST /orders failing"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 120
    run: |
      digest=$(cat /var/lib/drill/state 2>/dev/null || true)
      fault=""
      for cand in disk inodes config nofile perms; do
        h=$(printf '%s' "$cand" | sha256sum | awk '{print $1}')
        [ "$h" = "$digest" ] && fault="$cand"
      done
      if [ -z "$fault" ]; then
        echo "not yet: /var/lib/drill/state does not name a seeded fault."
        echo "         Start the lesson again — the scenario has to seed one before"
        echo "         it can be graded."
        exit 1
      fi

      # Outlast a Restart= that would put a killed process's damage back.
      sleep 3

      # ---- the symptom ----------------------------------------------------
      resp=$(curl -sS -m 8 -X POST --data 'sku=A-100&qty=1' http://127.0.0.1:8088/orders 2>&1 || true)
      if ! printf '%s' "$resp" | grep -q 'order accepted'; then
        state=$(systemctl is-active orders.service 2>/dev/null || true)
        echo "not yet: POST /orders answered: $(printf '%s' "$resp" | head -1)"
        echo "         orders.service is ${state:-unknown}. What the service itself said"
        echo "         about it is in journalctl -u orders."
        exit 1
      fi

      # ---- repaired where it lives, not around it -----------------------
      lpid=$(ss -ltnpH 'sport = :8088' 2>/dev/null | grep -o 'pid=[0-9]*' | head -1 | cut -d= -f2 || true)
      if [ -z "$lpid" ] || ! grep -q 'orders\.service' "/proc/$lpid/cgroup" 2>/dev/null; then
        echo "not yet: whatever answers on 127.0.0.1:8088 is not orders.service"
        echo "         (listener pid ${lpid:-unknown}). A copy started by hand stops the"
        echo "         next time you log out and never restarts; the unit has to run it."
        exit 1
      fi
      if [ "$(systemctl show -p User --value orders.service)" != orders ]; then
        echo "not yet: orders.service runs as '$(systemctl show -p User --value orders.service)',"
        echo "         not orders. Anything that stops the orders user writing is still"
        echo "         broken; running as someone else only stops you seeing it."
        exit 1
      fi
      if ! systemctl show -p ExecStart --value orders.service | grep -q '/opt/orders/orders\.py'; then
        echo "not yet: orders.service no longer runs /opt/orders/orders.py."
        exit 1
      fi
      if [ "$(sha256sum /opt/orders/orders.py | awk '{print $1}')" != "$(cat /var/lib/drill/program)" ]; then
        echo "not yet: /opt/orders/orders.py has changed. Nothing seeded was in the"
        echo "         program; put it back and repair the box around it."
        exit 1
      fi
      cval() { sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" /etc/orders/orders.conf 2>/dev/null | tail -1; }
      if [ "$(cval spool)" != /srv/orders/spool ] || [ "$(cval log)" != /srv/orders/log/orders.log ]; then
        echo "not yet: orders.conf points spool or log somewhere else (spool=$(cval spool),"
        echo "         log=$(cval log)). Writing somewhere that works leaves the place"
        echo "         that does not work broken, with 40 pending orders in it."
        exit 1
      fi
      if ! mountpoint -q /srv/orders; then
        echo "not yet: /srv/orders is no longer a mounted filesystem."
        exit 1
      fi
      size=$(df --output=size -m /srv/orders | tail -1 | tr -dc '0-9')
      itotal=$(df --output=itotal /srv/orders | tail -1 | tr -dc '0-9')
      if [ "$size" != 48 ] || [ "$itotal" != 4000 ]; then
        echo "not yet: /srv/orders is now ${size}M with $itotal inodes; it was 48M with"
        echo "         4000. A bigger filesystem runs out later of the same thing — and"
        echo "         a real disk cannot be remounted bigger mid-incident."
        exit 1
      fi
      if [ -n "$(find /srv/orders/spool -maxdepth 0 -perm -o+w 2>/dev/null)" ]; then
        echo "not yet: /srv/orders/spool is writable by every user on the box"
        echo "         ($(stat -c '%A %U:%G' /srv/orders/spool)). Give it to the user that"
        echo "         writes to it instead."
        exit 1
      fi
      missing=0
      for i in $(seq -w 1 40); do
        [ -f "/srv/orders/spool/ORD-seed-$i.order" ] || missing=$(( missing + 1 ))
      done
      if [ "$missing" -gt 0 ]; then
        echo "not yet: $missing of the 40 pending orders in /srv/orders/spool are gone."
        echo "         They were customers' orders, not the problem."
        exit 1
      fi

      case "$fault" in
        disk)
          held=$(lsof -nP +L1 2>/dev/null | grep ' /srv/orders/' || true)
          if [ -n "$held" ]; then
            echo "not yet: a process still holds a deleted file under /srv/orders open:"
            printf '%s\n' "$held" | sed 's/^/         /'
            echo "         While it holds that descriptor the space is its to take again."
            echo "         Stop the unit it belongs to."
            exit 1
          fi
          if systemctl is-active --quiet orders-export.service; then
            echo "not yet: orders-export.service is running again. Killed rather than"
            echo "         stopped, Restart=always brings it back and it fills the disk again."
            exit 1
          fi
          ;;
        inodes)
          iuse=$(df --output=ipcent /srv/orders | tail -1 | tr -dc '0-9')
          if [ "${iuse:-100}" -ge 50 ]; then
            echo "not yet: /srv/orders is at ${iuse}% of its inodes. Orders go through"
            echo "         now, a few at a time, into the headroom you freed; whatever is"
            echo "         holding the rest is still there."
            exit 1
          fi
          ;;
        nofile)
          lim=$(systemctl show -p LimitNOFILE --value orders.service)
          case "$lim" in infinity) lim=1048576 ;; ''|*[!0-9]*) lim=0 ;; esac
          if [ "$lim" -lt 256 ]; then
            echo "not yet: orders.service has LimitNOFILE=$lim in its unit. The running"
            echo "         process may have more (prlimit), and the next restart puts it"
            echo "         back to $lim."
            exit 1
          fi
          if [ "$(systemctl show -p NoNewPrivileges --value orders.service)" != yes ]; then
            echo "not yet: orders.service lost NoNewPrivileges=yes. The hardening drop-in"
            echo "         was right about that; only its descriptor limit was wrong."
            exit 1
          fi
          ;;
      esac

      # ---- the red herring ----------------------------------------------
      if [ ! -f /srv/orders/log/orders.log.1 ]; then
        echo "not yet: /srv/orders/log/orders.log.1 is gone. It was yesterday's log,"
        echo "         rotated and closed; its errors were retried and resolved. Deleting"
        echo "         it frees its own 12M and nothing else — it was never the fault."
        exit 1
      fi
      if [ "$(sha256sum /srv/orders/log/orders.log.1 | awk '{print $1}')" != "$(cat /var/lib/drill/herring)" ]; then
        echo "not yet: /srv/orders/log/orders.log.1 has changed. It was yesterday's"
        echo "         log, closed and innocent; put it back as it was."
        exit 1
      fi

      # ---- naming it ------------------------------------------------------
      if [ ! -s /root/answers/triage.md ]; then
        echo "not yet: /root/answers/triage.md is missing or empty. Three lines:"
        echo "         cause, evidence, detection."
        exit 1
      fi
      low=$(tr 'A-Z' 'a-z' < /root/answers/triage.md)
      field() { printf '%s\n' "$low" | sed -n "s/^[[:space:]]*$1[[:space:]]*[:=][[:space:]]*//p" | awk 'NR==1'; }
      a_cause=$(field cause); a_ev=$(field evidence); a_det=$(field detection)

      case "$fault" in
        disk)
          what="orders-export held a deleted scratch file open and it filled /srv/orders"
          c_re='\b(deleted|unlinked|held|still open|open file|orders-export|export)\b'
          e_re='\blsof\b|/proc/[^ ]*/fd|\bdf\b.*\bdu\b|\bdu\b.*\bdf\b'
          e_say="lsof +L1 (or df and du disagreeing, or the fd under /proc)"
          d_re='\b(disk|space|bytes|usage|df|full|filesystem)\b'
          d_say="filesystem space used (df), percent full" ;;
        inodes)
          what="an aborted import left thousands of empty .part files and used every inode"
          c_re='\binodes?\b'
          e_re='\bdf\b[^|]*-[a-z]*i\b|--inodes|\biuse|\bifree|\binodes?\b'
          e_say="df -i, where IUse% was 100 and bytes were not"
          d_re='\b(inodes?|iuse%?|ifree|df -i)\b'
          d_say="inode use (df -i), percent used" ;;
        config)
          what="port = 8O88 in orders.conf (a letter O), so the unit failed until systemd gave up"
          c_re='\b(config|conf|orders\.conf|port|typo|8o88)\b'
          e_re='\bjournalctl\b|\bsystemctl status\b|\bvalueerror\b'
          e_say="journalctl -u orders, which has the traceback"
          d_re='\b(unit|failed|active|restarts?|nrestarts|down|start|systemd|health|probe|synthetic)\b'
          d_say="the unit leaving active, restart count, or a synthetic write probe failing" ;;
        nofile)
          what="a hardening drop-in set LimitNOFILE one above what orders already held"
          c_re='\b(limitnofile|nofile|descriptors?|fds?|emfile|ulimit|open files)\b'
          e_re='/proc/[^ ]*/(fd|limits)|\blsof\b|\bprlimit\b|\blimitnofile\b|\bsystemctl (show|cat)\b'
          e_say="ls /proc/<pid>/fd | wc -l against /proc/<pid>/limits"
          d_re='\b(fds?|descriptors?|open files|nofile|emfile)\b'
          d_say="open descriptors as a share of the limit" ;;
        perms)
          what="/srv/orders/spool came back root:root 0755 and the service runs as orders"
          c_re='\b(permissions?|owner|ownership|owned|chown|chmod|mode|eacces|denied|root)\b'
          e_re='\bnamei\b|\bls\b|\bstat\b|\brunuser\b|\bsudo\b|\bsu\b|\btest -w\b|\bjournalctl\b'
          e_say="namei -l or ls -ld on the spool, or a write tried as orders"
          d_re='\b(eacces|permission|denied|errors?|5xx|500|failed|failures?|error rate)\b'
          d_say="write errors (5xx, EACCES) on POST /orders" ;;
      esac

      fail=0
      if [ -z "$a_cause" ] || ! printf '%s' "$a_cause" | grep -Eq "$c_re"; then
        fail=1
        echo "not yet: cause says '${a_cause:-nothing}', and orders takes writes, so"
        echo "         something was repaired. What was seeded:"
        echo "         $what."
      fi
      if [ -z "$a_ev" ] || ! printf '%s' "$a_ev" | grep -Eq "$e_re"; then
        fail=1
        echo "not yet: evidence says '${a_ev:-nothing}'. For this fault the proof is"
        echo "         $e_say."
      fi
      if [ -z "$a_det" ] || ! printf '%s' "$a_det" | grep -Eq "$d_re"; then
        fail=1
        echo "not yet: detection says '${a_det:-nothing}'. Name a signal that would have"
        echo "         paged before the first failed order: $d_say."
      elif ! printf '%s' "$a_det" | grep -q '[0-9]'; then
        fail=1
        echo "not yet: detection names a signal and no threshold. Say at what number"
        echo "         it pages — '> 90% for 5 minutes', with the number."
      fi
      [ "$fail" -eq 0 ] || exit 1

      echo "PASS — the seeded fault ($fault) was repaired at its cause; orders runs as"
      echo "       its unit, as orders, on its own filesystem, and orders.log.1 survived."
---
