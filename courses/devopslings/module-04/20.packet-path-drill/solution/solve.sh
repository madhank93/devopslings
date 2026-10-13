#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Follows a lookup outward from the storefront — what the name resolves to,
# whether the box forwards, which route wins for orders, whether the listener
# can hold a burst, whether the reply is rewritten on its way back — and repairs
# the configuration the first wrong answer points at. It never reads
# /var/lib/packet-drill.
set -euo pipefail

aaaa=$(ip netns exec storefront getent ahosts orders.internal \
         | awk '$1 ~ /:/ && $1 !~ /^::ffff:/ {print $1; exit}' || true)
stale=$(ip route show match 10.72.0.5 | awk '/proto 199/ {print $1; exit}' || true)
smx=$(ip netns exec orders sysctl -n net.core.somaxconn)

# 1. Every address the name resolves to has to answer.
if [ -n "$aaaa" ] && ! ip netns exec storefront curl -s -m 1 -g "http://[$aaaa]:8080/" >/dev/null; then
  real=$(ip netns exec orders ip -6 -o addr show dev eth0-in scope global | awk '{split($4, a, "/"); print a[1]; exit}')
  # /etc/hosts is a bind mount: rewrite it in place.
  awk -v bad="$aaaa" -v good="$real" '$1 == bad {$1 = good} {print}' /etc/hosts > /root/hosts.new
  cat /root/hosts.new > /etc/hosts
  rm -f /root/hosts.new
  cause="orders.internal's AAAA, $aaaa, is not routed to anything, so every lookup waited out its IPv6 connect timeout before trying IPv4"
  evidence="getent ahosts orders.internal lists $aaaa; shop-probe: over budget at 2.0s, connected over ipv4"
  detection="connect latency p99 > 500ms, or any published AAAA failing a connect check > 0 times"

# 2. The box has to forward: every lookup is DNAT'd and routed back out.
elif [ "$(sysctl -n net.ipv4.ip_forward)" != 1 ]; then
  # The router's exception has to sort after the baseline it overrides.
  mv /etc/sysctl.d/30-shop-router.conf /etc/sysctl.d/90-shop-router.conf
  sysctl -q -p /etc/sysctl.d/90-shop-router.conf
  cause="60-cis-network.conf sets net.ipv4.ip_forward = 0 and sorts after 30-shop-router.conf, so the box stopped forwarding"
  evidence="sysctl net.ipv4.ip_forward = 0; IpInAddrErrors climbing in nstat during shop-probe"
  detection="ip_forward != 1 on a box that routes, or IpInAddrErrors > 0 per minute"

# 3. Only the bridge's own /24 should cover orders.
elif [ -n "$stale" ]; then
  awk -v p="$stale" '$1 != p' /etc/shopnet/routes > /root/routes.new
  cat /root/routes.new > /etc/shopnet/routes
  rm -f /root/routes.new
  systemctl restart shopnet.service
  cause="a stale $stale route via 172.31.0.99 in /etc/shopnet/routes is more specific than br-shop's /24"
  evidence="ip route get 10.72.0.5 chose via 172.31.0.99 dev eth0"
  detection="ip route get for a backend leaving by an unexpected next hop > 0, or neighbour 172.31.0.99 INCOMPLETE"

# 4. The listener gets min(backlog, somaxconn) in its own namespace.
elif [ "$smx" -lt 128 ]; then
  sed -i 's/^net\.core\.somaxconn.*/net.core.somaxconn = 4096/' /etc/shopnet/orders.sysctl
  systemctl restart shopnet.service
  systemctl restart orders.service
  cause="net.core.somaxconn = $smx in orders' namespace capped its 1024 backlog, and a burst overflowed the accept queue"
  evidence="nstat in the orders namespace: TcpExtListenOverflows climbing; ss -lnt shows Send-Q $smx"
  detection="ListenOverflows > 0 per minute in the service's namespace"

# 5. A lookup from the segment itself must come back through the box.
elif ! grep -q 'ct status dnat masquerade' /etc/shopnet/nat.nft; then
  python3 - <<'PY'
p = "/etc/shopnet/nat.nft"
s = open(p).read()
hook = "type nat hook postrouting priority 100; policy accept;\n"
assert s.count(hook) == 1
rule = "    ip saddr 10.72.0.0/24 ip daddr 10.72.0.5 tcp dport 8080 ct status dnat masquerade\n"
open(p, "w").write(s.replace(hook, hook + rule))
PY
  systemctl restart shopnet.service
  cause="nat.nft lost the hairpin masquerade, so orders replied straight to 10.72.0.6 and the storefront reset a reply it did not recognise"
  evidence="tcpdump -ni br-shop: SYN-ACK from 10.72.0.5 to 10.72.0.6, answered by RST"
  detection="a synthetic lookup through 203.0.113.20 from inside the segment failing > 0 times in 5 minutes"

else
  echo "no question answered, and the scenario seeds a fault on every run" >&2
  exit 1
fi

install -d /root/answers
printf 'cause: %s\nevidence: %s\ndetection: %s\n' "$cause" "$evidence" "$detection" > /root/answers/triage.md
