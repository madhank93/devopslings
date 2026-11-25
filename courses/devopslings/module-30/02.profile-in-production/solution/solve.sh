#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Production's profile is ~90% normalize_lines: it scans the merged list for
# every line, so acme's 2000-line orders cost 2000² comparisons. A dict keyed
# by SKU keeps first-seen order (dicts are ordered) and is linear.
set -euo pipefail
mkdir -p /obs/answers
echo "hot_function=normalize_lines" > /obs/answers/profile.txt
python3 - <<'PY'
p = "/obs/pricing/pricing.py"
s = open(p).read()
old = s[s.index("    merged = []\n"):s.index("    return merged\n") + len("    return merged\n")]
new = '''    merged = {}
    for line in lines:
        m = merged.get(line["sku"])
        if m:
            m["qty"] += line["qty"]
        else:
            merged[line["sku"]] = {"sku": line["sku"], "qty": line["qty"], "unit": line["unit"]}
    return list(merged.values())
'''
open(p, "w").write(s.replace(old, new))
PY
