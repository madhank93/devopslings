#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# Case 1: the /api/ split is written in each HTTP request's path, so only a
# balancer that parses HTTP can make it. Key custody alone would not force L7:
# an L4 TLS listener terminates TLS without reading the HTTP inside.
# Case 2: an in-house binary protocol; there is nothing for an L7 balancer to parse.
# Case 3: the application must see the caller's address on the connection
# itself, which a terminating balancer replaces with its own.
# Case 4: the backend must hold the only key and verify the caller's
# certificate, so the TLS session may not end at the balancer at all.
cat > /root/answers/verdict.md <<'ANS'
case-1: layer=l7 because=routing
case-2: layer=l4 because=protocol
case-3: layer=l4 because=sourceaddress
case-4: layer=l4 because=termination
ANS
