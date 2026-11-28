#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Every record reports writes starts with its timestamp; a traceback's lines
# do not. The filelog receiver's multiline rule starts a new record only at a
# timestamped line and appends everything else to the record before it.
set -euo pipefail
python3 - <<'PY'
p = "/obs/otel/collector.yaml"
s = open(p).read()
old = "    start_at: end\n"
assert old in s
s = s.replace(old, old + "    multiline:\n      line_start_pattern: '^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2},\\d{3} '\n")
open(p, "w").write(s)
PY
grep -q line_start_pattern /obs/otel/collector.yaml
