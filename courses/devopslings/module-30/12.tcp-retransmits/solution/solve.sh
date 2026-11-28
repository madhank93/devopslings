#!/bin/sh
set -e
# tcpretrans.bt names fx-rates (10.81.2.2) on every line; the loss sits on
# eth0 inside its namespace, out of sight of the host's own tc.
ip netns exec fx-rates tc qdisc del dev eth0 root
mkdir -p /root/answers
cat > /root/answers/retrans.md <<'ANS'
peer: 10.81.2.2
cause: netem loss 3% on eth0 inside the fx-rates network namespace
ANS
