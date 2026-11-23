#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# memleak -p <pid> shows the outstanding bytes growing under
#   strdup <- normalize_key <- lookup <- main
# lookup() hands the key to the table on a miss and drops it on a hit; free
# it there.
set -euo pipefail
install -d /root/answers
echo "allocation_site=normalize_key" > /root/answers/heap.txt
python3 - <<'PY'
p = "/usr/local/src/session-cache/session-cache.c"
s = open(p).read()
old = "        hits++;\n        return e->token;\n"
assert old in s
open(p, "w").write(s.replace(old, "        hits++;\n        free(key);\n        return e->token;\n"))
PY
make -s -C /usr/local/src/session-cache install
systemctl restart session-cache.service
sleep 3
