#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

# the bridge is what docker0 is
ip link add br0 type bridge
ip addr add 10.77.0.1/24 dev br0
ip link set br0 up

# a veth pair is what every container gets, one end renamed eth0 inside
i=2
for ns in app1 app2; do
  ip link add "veth-$ns" type veth peer name eth0-in
  ip link set eth0-in netns "$ns"
  ip link set "veth-$ns" master br0
  ip link set "veth-$ns" up

  ip netns exec "$ns" ip addr add "10.77.0.$i/24" dev eth0-in
  ip netns exec "$ns" ip link set eth0-in up
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip route add default via 10.77.0.1
  i=$((i + 1))
done

# the box becoming a router is what makes bridge networking work at all
sysctl -w net.ipv4.ip_forward=1 >/dev/null

# masquerade is why containers can reach the internet while nothing can reach them back
nft add table ip lab-nat
nft 'add chain ip lab-nat post { type nat hook postrouting priority 100 ; }'
nft add rule ip lab-nat post ip saddr 10.77.0.0/24 oifname "eth0" masquerade

# The pause is for the bridge to finish learning, not for the configuration —
# that is already complete by the time this line runs.
sleep 1
