#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Each HAProxy holds the certificate it read at its last start or reload, so
# every node is reloaded in place. A master-worker reload hands the listening
# sockets to the new workers: no connection is refused and none is cut.
set -euo pipefail
cat > /ha/answers/cert-rotation.txt <<'TXT'
rotate_on: lb1 lb2
vip_move_rotates: nothing
TXT

cat > /ha/certs/rotate.sh <<'SH'
#!/bin/bash
set -euo pipefail
fp() { openssl x509 -noout -fingerprint -sha256 | cut -d= -f2; }
want=$(fp < /ha/certs/www.pem)
for l in lb1:172.29.22.11 lb2:172.29.22.12; do
  node=${l%%:*} ip=${l#*:}
  touch "/ha/$node/start-haproxy"
  for _ in $(seq 40); do
    got=$(openssl s_client -connect "$ip:443" -servername www </dev/null 2>/dev/null | fp 2>/dev/null || true)
    [ "$got" = "$want" ] && continue 2
    sleep 0.5
  done
  echo "rotate: $node still presents an old certificate" >&2
  exit 1
done
SH
chmod +x /ha/certs/rotate.sh
bash /ha/certs/rotate.sh
