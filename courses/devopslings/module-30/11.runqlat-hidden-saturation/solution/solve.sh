#!/bin/sh
set -e
mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing

# quote-api's run-queue wait while requests run, as runqlat.bt measures it;
# prints the p99 bucket's upper bound in milliseconds.
p99_ms() {
  timeout -s INT 6 bpftrace -e '
    tracepoint:sched:sched_wakeup, tracepoint:sched:sched_wakeup_new { @q[args.pid] = nsecs; }
    tracepoint:sched:sched_switch {
      if (args.prev_state == 0) { @q[args.prev_pid] = nsecs; }
      $ns = @q[args.next_pid];
      if ($ns && args.next_comm == "quote-api") { @ms = hist((nsecs - $ns) / 1000000); }
      delete(@q, args.next_pid);
    }
    END { clear(@q); }' > /tmp/rq.out 2>&1 &
  sleep 2
  python3 -c '
import time, urllib.request
end = time.time() + 3.5
while time.time() < end:
    urllib.request.urlopen("http://127.0.0.1:8095/").read(); time.sleep(0.005)'
  wait
  python3 -c '
import re
rows = []
for l in open("/tmp/rq.out"):
    m = re.match(r"\[(\d+)(?:, (\d+))?[\])]\s+(\d+)", l)
    if m:
        rows.append((int(m.group(2) or m.group(1)), int(m.group(3))))
total, acc = sum(n for _, n in rows), 0
for hi, n in rows:
    acc += n
    if acc >= 0.99 * total:
        print(hi); break'
}

before=$(p99_ms)
# Both pinned to CPUs 0-1 and the batch saturates them. Give quote-api CPUs
# nothing else is pinned to.
mkdir -p /etc/systemd/system/quote-api.service.d
printf '[Service]\nCPUAffinity=2 3\n' > /etc/systemd/system/quote-api.service.d/cpus.conf
systemctl daemon-reload
systemctl restart quote-api.service
for _ in $(seq 40); do curl -fsS -o /dev/null http://127.0.0.1:8095/ 2>/dev/null && break; sleep 0.25; done
after=$(p99_ms)

mkdir -p /root/answers
cat > /root/answers/runqlat.md <<ANS
before-p99-ms: $before
after-p99-ms: $after
cause: quote-api is pinned to CPUs 0-1, which nightly-reindex's eight CPU-bound workers saturate
ANS
cat /root/answers/runqlat.md
