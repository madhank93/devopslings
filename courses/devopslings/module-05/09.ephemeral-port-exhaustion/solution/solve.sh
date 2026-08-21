#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# one connection per request is what consumes a port per request; reusing the
# connection needs one port for the whole run, and it is the only fix here that
# also stops the box hammering the server's accept path
python3 - <<'PY'
path = "/etc/loadgen.conf"
lines = []
seen = False
for line in open(path):
    if line.strip().lower().startswith("keepalive"):
        lines.append("keepalive=yes\n")
        seen = True
    else:
        lines.append(line)
if not seen:
    lines.append("keepalive=yes\n")
open(path, "w").writelines(lines)
PY

install -d /root/answers
cat > /root/answers/ports.md <<'ANS'
connect_error: cannot assign requested address
who_holds_time_wait: client
ANS
