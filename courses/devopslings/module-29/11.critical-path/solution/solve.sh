#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The six GET /stock calls run one after another (~485ms) while
# recommendations (~300ms) runs beside them, so the stock chain is the
# critical path. Run side by side they take as long as the slowest warehouse
# (~100ms), and recommendations becomes the longest branch: the request saves
# the chain minus recommendations, about 485 - 300 = 185ms.
set -euo pipefail
python3 - <<'PY'
p = "/obs/apps/checkout.py"
s = open(p).read()
s = s.replace("    available = sum(stock(w) for w in WAREHOUSES)\n",
              "    pending = [in_background(stock, w) for w in WAREHOUSES]\n"
              "    available = sum(wait() for wait in pending)\n")
open(p, "w").write(s)
PY
grep -q 'in_background(stock, w)' /obs/apps/checkout.py
sed -i -e 's/^chain: ?.*/chain: GET \/stock/' -e 's/^saving_ms: ?.*/saving_ms: 185/' /obs/answers/critical-path.txt
