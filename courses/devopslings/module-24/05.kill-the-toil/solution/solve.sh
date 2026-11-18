#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The archive step is one statement: DELETE ... RETURNING feeds the INSERT,
# so a second copy running at the same moment blocks on the row locks and
# then finds nothing left to move. Each run reports what it changed itself.
set -euo pipefail
cat > /ha/sre/weekly-cleanup <<'PY'
#!/usr/bin/env python3
"""Monday clean-up: expired carts and 90-day-old orders. Safe to run on both web nodes at once."""
import socket
import time

import psycopg

t0 = time.monotonic()
dsn = next(l.split("=", 1)[1].strip() for l in open("/ha/app.env") if l.startswith("DB_DSN="))
with psycopg.connect(dsn, autocommit=True) as c:
    carts = c.execute("DELETE FROM toil.carts WHERE touched_at < now() - interval '7 days'").rowcount
    orders = c.execute(
        "WITH moved AS (DELETE FROM toil.orders WHERE placed_at < now() - interval '90 days' RETURNING *) "
        "INSERT INTO toil.orders_archive SELECT * FROM moved").rowcount
with open("/ha/sre/toil.log", "a") as f:
    f.write(f"{time.strftime('%Y-%m-%dT%H:%M:%S')} node={socket.gethostname()} "
            f"carts_deleted={carts} orders_archived={orders} seconds={time.monotonic() - t0:.2f}\n")
PY
chmod +x /ha/sre/weekly-cleanup
cat > /ha/app/scheduler.sh <<'SH'
#!/bin/bash
# A week is 15 seconds in the sandbox; run well inside it.
while :; do
  /ha/sre/weekly-cleanup || echo "weekly-cleanup failed with $?"
  sleep 10
done
SH
