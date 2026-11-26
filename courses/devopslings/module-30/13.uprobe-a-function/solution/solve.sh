#!/bin/sh
set -e
mountpoint -q /sys/kernel/tracing || mount -t tracefs tracefs /sys/kernel/tracing
cat > /root/uprobe.bt <<'BT'
uprobe:/opt/pricer/pricer:price_lookup { @start[tid] = nsecs; }
uretprobe:/opt/pricer/pricer:price_lookup /@start[tid]/
{
  @us = hist((nsecs - @start[tid]) / 1000);
  @avg_us = avg((nsecs - @start[tid]) / 1000);
  delete(@start[tid]);
}
END { clear(@start); }
BT
# timeout exits 124 when it stops bpftrace, which is the normal end here.
timeout -s INT 4 bpftrace /root/uprobe.bt > /tmp/uprobe.out 2>/dev/null || true
avg=$(sed -n 's/^@avg_us: //p' /tmp/uprobe.out)
mkdir -p /root/answers
echo "latency-ms: $((avg / 1000))" > /root/answers/latency.md
cat /root/answers/latency.md
