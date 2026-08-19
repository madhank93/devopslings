#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# dig speaks to the DNS server itself. getaddrinfo() does not: it consults the
# sources named on the hosts line of /etc/nsswitch.conf, in order, and that line
# named only files and myhostname. With no dns source on it, a perfectly correct
# resolver is never asked. Adding dns puts it back in the lookup path.
sed -i 's/^hosts:.*$/hosts:          files dns myhostname/' /etc/nsswitch.conf

install -d /root/answers
cat > /root/answers/resolution.md <<'ANS'
file=/etc/nsswitch.conf missing=dns
ANS
