#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Reads the SPOFs off the running configuration: a load balancer is single when
# it is the only one with a keepalived config, web1 is single unless web2 is an
# active or backup server, and pg1 is always single because the app writes only
# there. The grader's kill test is the ground truth this has to agree with.
set -euo pipefail

{
  holders=$(for l in lb1 lb2; do [ -f "/ha/$l/keepalived.conf" ] && echo "$l"; done; true)
  [ "$(wc -w <<<"$holders")" -eq 1 ] && echo "$holders"
  if ! grep -E '^[[:space:]]*server[[:space:]]+web2\b' /ha/haproxy.cfg | grep -qvw disabled; then
    echo web1
  fi
  echo pg1
} > /ha/answers/spof.txt
cat /ha/answers/spof.txt
