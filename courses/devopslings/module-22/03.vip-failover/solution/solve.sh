#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Both load balancers in one VRRP group (same virtual_router_id), lb1 preferred.
# VRRPv3 allows sub-second adverts: at 0.2s a backup takes over about 0.7s
# after the master stops advertising.
set -euo pipefail
mkdir -p /ha/lb2
for n in lb1 lb2; do
  if [ "$n" = lb1 ]; then state=MASTER prio=150; else state=BACKUP prio=100; fi
  cat > "/ha/$n/keepalived.conf" <<CONF
global_defs {
    vrrp_version 3
}
vrrp_instance www {
    state $state
    interface eth0
    virtual_router_id 22
    priority $prio
    advert_int 0.2
    virtual_ipaddress {
        172.29.22.100/24
    }
}
CONF
done
sed -i 's/^measured_before:.*/measured_before: 3.6/' /ha/answers/failover.txt
sleep 4
