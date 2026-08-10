#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# SO_KEEPALIVE is off by default on every TCP socket, so the kernel timers below
# apply to nothing until the application opts in; the file is rewritten rather
# than edited in place because `sed -i` fails on a container bind mount.
sed 's/^keepalive=off/keepalive=on/' /etc/pool.conf > /tmp/pool.conf.new
cat /tmp/pool.conf.new > /etc/pool.conf

# The keepalive timers live in the network namespace of the process that owns
# the socket, so setting them on the box would have no effect on a process in
# pool-client; five seconds is chosen to be comfortably under the middlebox's
# fifteen, because a keepalive that arrives after the flow has been forgotten
# is just a packet that gets dropped; and the point is to refresh the flow
# while the middlebox still remembers it, not to detect the failure faster.
ip netns exec pool-client sysctl -w net.ipv4.tcp_keepalive_time=5 >/dev/null
ip netns exec pool-client sysctl -w net.ipv4.tcp_keepalive_intvl=3 >/dev/null
ip netns exec pool-client sysctl -w net.ipv4.tcp_keepalive_probes=3 >/dev/null
