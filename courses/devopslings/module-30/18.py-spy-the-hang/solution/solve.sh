#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# py-spy dump --pid <worker> shows "settler" blocked in settle_one on
# `with fees_lock` and "reconciler" blocked in reconcile_one on
# `with ledger_lock`: each holds the lock the other wants. The reconciler
# takes the locks in the settler's order, ledger then fees.
set -euo pipefail
install -d /root/answers
printf 'settler_waits_for=fees_lock\nreconciler_waits_for=ledger_lock\n' > /root/answers/hang.txt
python3 - <<'PY'
p = "/opt/settle/worker.py"
s = open(p).read()
old = "    with fees_lock:\n        journal()\n        with ledger_lock:\n"
assert old in s
open(p, "w").write(s.replace(old, "    with ledger_lock:\n        journal()\n        with fees_lock:\n"))
PY
systemctl restart settle-worker.service
