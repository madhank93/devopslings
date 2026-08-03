#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The evidence first, because raising the limit changes the answer to the
# second question.
set -euo pipefail

install -d /root/answers
echo oom > /root/answers/killer
systemctl show -p MemoryMax --value report-builder.service > /root/answers/limit

# The fix is the allocation, not the limit. The builder held three full copies
# of the data — a dict per row with 4 KiB of padding, then a formatted string
# per row, then the joined result — for a job that only ever needs one row at a
# time. Streaming it keeps peak memory flat regardless of input size.
cat > /usr/local/bin/report-builder <<'SH'
#!/usr/bin/env python3
print("report-builder: starting", flush=True)

n = 0
with open("/srv/reports/orders.tsv") as f, open("/srv/reports/daily.csv", "w") as out:
    out.write("order_id,sku,qty,unit_price,total\n")
    for line in f:
        oid, sku, qty, price = line.rstrip("\n").split("\t")
        qty, price = int(qty), float(price)
        out.write(f"{oid},{sku},{qty},{price:.2f},{qty*price:.2f}\n")
        n += 1

print(f"report-builder: wrote {n} rows", flush=True)
SH
chmod 0755 /usr/local/bin/report-builder

# The limit stays. It was never the bug, and it is what kept this to one unit
# instead of the whole box.
