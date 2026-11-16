#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A management network of its own, joined by both load balancers, with each
# node's runtime API bound to that node's address there. Nothing on the path
# depends on the VIP, the front network or the state the drain destroyed.
set -euo pipefail
cat > /ha/answers/facebook-2021.txt <<'TXT'
front_network: yes
the_vip: yes
haproxy_on_the_vip_holder: yes
an_enabled_server: yes
pg1: no
etcd: no
TXT

net=devopslings-ha-oob
docker network inspect "$net" >/dev/null 2>&1 || docker network create --subnet 172.29.24.0/24 "$net" >/dev/null
for l in lb1:172.29.24.11 lb2:172.29.24.12; do
  c=devopslings-ha-${l%%:*}
  docker inspect -f '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' "$c" | grep -qw "$net" \
    || docker network connect --ip "${l#*:}" "$net" "$c"
done

# Both addresses on both nodes: transparent lets each bind the one it does not own.
grep -q 'ipv4@172.29.24.11:9999' /ha/haproxy.cfg || sed -i '/^global$/a\
    stats socket ipv4@172.29.24.11:9999 level admin transparent\
    stats socket ipv4@172.29.24.12:9999 level admin transparent' /ha/haproxy.cfg

cat > /ha/oob/console.env <<'ENV'
NETWORK=devopslings-ha-oob
LB1=172.29.24.11:9999
LB2=172.29.24.12:9999
ENV
cat > /ha/oob/rollback.sh <<'SH'
#!/bin/bash
set -euo pipefail
for api in "$LB1" "$LB2"; do
  exec 3<>"/dev/tcp/${api%:*}/${api##*:}"
  echo "enable server app/web1; enable server app/web2" >&3
  cat <&3
  exec 3<&-
done
SH
chmod +x /ha/oob/rollback.sh

