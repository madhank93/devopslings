#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# Case 1 requires L7 termination because the application team doesn't hold
# the private key, making L7 the mandatory requirement despite other factors
# that might prefer L7.
# Case 2 requires L4 because the binary protocol is unknown to the L7 balancer
# and cannot be parsed meaningfully.
# Case 3 requires L4 because the application must log the true client address,
# and L7 termination would replace that address with the balancer's IP. The
# usual answer here is an X-Forwarded-For header, and the auditors rejected it:
# it asks the application to trust a header instead of the connection.
# Case 4 requires L4 because the routing key for read-only routing is not
# available at connection time, even though the protocol is well known.
# Cases 2 and 4 share the 'protocol' token for opposite reasons — in case 2 the
# balancer cannot parse the protocol at all, and in case 4 it parses it fine but
# the thing it would route on has not been sent yet.
cat > /root/answers/verdict.md <<'ANS'
case-1: layer=l7 because=termination
case-2: layer=l4 because=protocol
case-3: layer=l4 because=sourceaddress
case-4: layer=l4 because=protocol
ANS
