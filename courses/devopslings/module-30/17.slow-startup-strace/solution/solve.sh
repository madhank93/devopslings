#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# strace -f -T -e trace=network,poll on the starting service shows a
# sendto() to 10.53.0.53:53 and a poll(..., 5000) = 0 (Timeout) <5.00>, twice:
# nsswitch asks DNS before /etc/hosts, and the only nameserver is gone. Put
# files first; the decommissioned server leaves resolv.conf too. resolv.conf
# is a bind mount, so it is rewritten in place.
set -euo pipefail
install -d /root/answers
printf 'nameserver=10.53.0.53\ntimeout_seconds=5\n' > /root/answers/slow-startup.txt
sed 's/^hosts:.*/hosts:          files dns/' /etc/nsswitch.conf > /tmp/nsswitch.new
cat /tmp/nsswitch.new > /etc/nsswitch.conf
cat /var/lib/devopslings/resolv.conf.orig > /etc/resolv.conf
