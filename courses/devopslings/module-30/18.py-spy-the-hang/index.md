---
kind: lesson
title: "0% CPU, and the settlements stopped an hour ago"
description: |
  settle-worker stops moving money every few hours. It does not crash, it
  does not spin, it just stops, and a restart fixes it until the next time.
  py-spy can read every thread's Python stack out of the live process without
  stopping it. Read them before you restart anything, and fix the lock order
  they show.
name: py-spy-the-hang
slug: py-spy-the-hang
createdAt: "2026-11-22"

sandbox:
  stack: linux-box
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 180
    run: |
      systemctl stop settle-worker.service 2>/dev/null || true
      systemctl reset-failed settle-worker.service 2>/dev/null || true
      rm -rf /opt/settle /var/lib/settle /etc/systemd/system/settle-worker.service \
             /root/answers/hang.txt
      install -d /opt/settle /var/lib/settle /root/answers

      cat > /opt/settle/worker.py <<'PY'
      #!/usr/bin/python3
      """settle-worker: moves settled payments from the ledger into the fee pool,
      while a reconciler checks that money is neither created nor lost.

        worker.py                  run forever, as the service does
        worker.py --iterations N   do N rounds per thread, print a summary, exit
      """
      import json, os, sys, threading, time

      TOTAL = 1_000_000
      ledger = {"cents": TOTAL}
      fees = {"cents": 0}
      ledger_lock = threading.Lock()
      fees_lock = threading.Lock()
      stats = {"settled": 0, "reconciled": 0, "mismatches": 0}
      PROGRESS = "/var/lib/settle/progress"


      def journal():
          # The write-ahead journal: a short, blocking write while a lock is held.
          time.sleep(0.0005)


      def settle_one():
          with ledger_lock:
              ledger["cents"] -= 1
              journal()
              with fees_lock:
                  fees["cents"] += 1
                  journal()
          stats["settled"] += 1


      def reconcile_one():
          with fees_lock:
              journal()
              with ledger_lock:
                  if ledger["cents"] + fees["cents"] != TOTAL:
                      stats["mismatches"] += 1
          stats["reconciled"] += 1


      def loop(step, n, pause):
          i = 0
          while n == 0 or i < n:
              if pause:
                  time.sleep(pause)
              step()
              i += 1


      def main():
          n = int(sys.argv[2]) if len(sys.argv) > 2 and sys.argv[1] == "--iterations" else 0
          threads = [
              threading.Thread(target=loop, args=(settle_one, n, 0 if n else 0.01), name="settler"),
              threading.Thread(target=loop, args=(reconcile_one, n, 0 if n else 0.5), name="reconciler"),
          ]
          for t in threads:
              t.start()
          if n:
              for t in threads:
                  t.join()
              print(json.dumps(stats))
              return
          os.makedirs(os.path.dirname(PROGRESS), exist_ok=True)
          while True:
              with open(PROGRESS, "w") as f:
                  f.write(f"{stats['settled']} {stats['reconciled']}\n")
              time.sleep(0.5)


      if __name__ == "__main__":
          main()
      PY
      chmod 0755 /opt/settle/worker.py

      cat > /etc/systemd/system/settle-worker.service <<'UNIT'
      [Unit]
      Description=Payment settlement worker

      [Service]
      ExecStart=/usr/bin/python3 /opt/settle/worker.py
      Restart=on-failure
      UNIT
      systemctl daemon-reload

      # Wait for the unlucky interleaving: progress stops moving while the
      # process stays alive. It usually comes within seconds; restart and wait
      # again if it does not.
      hung=""
      for attempt in 1 2 3; do
        systemctl restart settle-worker.service
        prev=""; same=0
        for _ in $(seq 1 60); do
          sleep 1
          cur=$(cat /var/lib/settle/progress 2>/dev/null || true)
          if [ -n "$cur" ] && [ "$cur" = "$prev" ]; then same=$((same + 1)); else same=0; fi
          prev=$cur
          if [ "$same" -ge 2 ]; then hung=yes; break; fi
        done
        [ -n "$hung" ] && break
      done
      if [ -z "$hung" ]; then
        echo "scenario setup failed: settle-worker did not hang in three tries" >&2
        exit 1
      fi
      systemctl is-active -q settle-worker.service

      echo "scenario ready — settle-worker.service is active, at 0% CPU, and has settled nothing"
      echo "since $(date +%T). /var/lib/settle/progress shows the counts it stopped at."
      echo "Write your findings to /root/answers/hang.txt."

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 180
    run: |
      ans=/root/answers/hang.txt
      field() { { grep -iE "^$1=" "$ans" 2>/dev/null || true; } | tail -1 | cut -d= -f2- | tr -d ' "'; }
      s=$(field settler_waits_for); r=$(field reconciler_waits_for)
      if [ -z "$s" ] || [ -z "$r" ]; then
        echo "not yet: $ans needs settler_waits_for=<lock> and reconciler_waits_for=<lock>: the lock each"
        echo "         thread is blocked acquiring, read from py-spy dump of the hung process."
        exit 1
      fi
      if [ "$s" = ledger_lock ] && [ "$r" = fees_lock ]; then
        echo "not yet: those are the locks each thread already holds. py-spy dump points at the line each"
        echo "         thread is stopped on: the with statement it cannot get past."
        exit 1
      fi
      if [ "$s" != fees_lock ] || [ "$r" != ledger_lock ]; then
        echo "not yet: settler_waits_for=$s reconciler_waits_for=$r. In py-spy dump, the innermost frame of"
        echo "         each named thread shows the line it is blocked on; read the lock off that line."
        exit 1
      fi

      if [ ! -s /opt/settle/worker.py ]; then
        echo "not yet: /opt/settle/worker.py is missing. Reset the lesson to get it back."
        exit 1
      fi
      # The service's own pacing hides the race for seconds at a time; with no
      # pause between rounds, the original deadlocks within a few hundred.
      out=$(timeout 60 python3 /opt/settle/worker.py --iterations 2000 2>&1) && rc=0 || rc=$?
      if [ "$rc" = 124 ]; then
        echo "not yet: a stress run of 2000 rounds per thread hung (killed after 60 s). Restarting clears a"
        echo "         deadlock; only taking the locks in one order everywhere prevents the next one."
        exit 1
      fi
      if [ "$rc" != 0 ]; then
        echo "not yet: the stress run of /opt/settle/worker.py failed (exit $rc):"
        tail -5 <<<"$out"
        exit 1
      fi
      sum=$(tail -1 <<<"$out")
      settled=$(jq -r .settled <<<"$sum" 2>/dev/null || true)
      reconciled=$(jq -r .reconciled <<<"$sum" 2>/dev/null || true)
      mism=$(jq -r .mismatches <<<"$sum" 2>/dev/null || true)
      if [ "$settled" != 2000 ] || [ "$reconciled" != 2000 ]; then
        echo "not yet: the stress run settled ${settled:-?} and reconciled ${reconciled:-?} of 2000 each. A"
        echo "         round that gives up on a lock is a settlement that never happened."
        exit 1
      fi
      if [ "$mism" != 0 ]; then
        echo "not yet: the reconciler saw money missing $mism times in 2000 checks. It reads both balances;"
        echo "         without holding both locks it catches a settlement halfway, debited and not credited."
        exit 1
      fi
      echo "PASS — settler held ledger_lock waiting for fees_lock while reconciler held fees_lock waiting"
      echo "       for ledger_lock; 2000 rounds each now complete with no money missing."
---
