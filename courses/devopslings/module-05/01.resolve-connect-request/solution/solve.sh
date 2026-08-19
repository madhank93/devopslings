#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# alpha.internal:  dig returns NXDOMAIN. The resolver is authoritative for
#                  .internal, so this is a definite "no such name", not a
#                  timeout. No address means no connect attempt and no request.
# bravo.internal:  dig returns 10.70.0.6. nc -vz refuses immediately — a RST
#                  came back, so the host is up and nothing is listening on
#                  8080. The request was never written.
# charlie.internal: dig returns 10.70.0.7, the connection opens, the request
#                  goes out, and the response is HTTP 503. All three steps ran;
#                  the last one is the one that failed.
install -d /root/answers
cat > /root/answers/request.md <<'ANS'
alpha:   resolves=no  connects=na  http=na  step=resolve
bravo:   resolves=yes connects=no  http=na  step=connect
charlie: resolves=yes connects=yes http=503 step=request
ANS
