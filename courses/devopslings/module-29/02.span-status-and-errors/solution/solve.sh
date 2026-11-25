#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The exception is caught inside the span, so the SDK never sees it leave the
# `with` block. Record it on the span and set the error status where it is
# caught.
set -euo pipefail
python3 - <<'PY'
p = "/obs/apps/ledger.py"
s = open(p).read()
s = s.replace('''                code = 500
''', '''                span.record_exception(e)
                span.set_status(trace.Status(trace.StatusCode.ERROR, str(e)))
                code = 500
''')
open(p, "w").write(s)
PY
grep -q 'record_exception(e)' /obs/apps/ledger.py
