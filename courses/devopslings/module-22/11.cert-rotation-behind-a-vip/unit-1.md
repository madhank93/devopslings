---
title: "Certificate rotation behind a VIP"
---

## The situation

www now serves HTTPS on 443. The certificate is `/ha/certs/www.pem`, shared
by lb1 and lb2, and signed by the lab CA in `/ha/certs/ca.pem`. It was
renewed this morning, and the file holds the new certificate.

`curl https://www/` gets the new certificate, because lb1 holds the VIP and
lb1 was reloaded after the renewal. lb2 was not. It still has the old
certificate in memory and will present it the moment it takes over the
address. That happens on the next failover, possibly after the old
certificate has expired.

The obvious fix is to restart whichever node is serving the old
certificate. Each restart drops every connection on that node, and if the
node holds the VIP, the address moves while clients are mid-handshake.

## Your objectives

1. In `/ha/answers/cert-rotation.txt`, name the nodes that have to load a
   renewed certificate themselves, and say what moving the VIP rotates.
2. Both nodes present the certificate that is in `/ha/certs/www.pem`.
3. Write `/ha/certs/rotate.sh`. Run after the next renewal, it makes every
   node present the new certificate without one failed connection or
   handshake.

## What you're being graded on

The answers first. Then the grader checks that both nodes already present
the current file. It issues a new certificate into `/ha/certs/www.pem` and
starts clients that open a new TLS connection for every request. The
clients connect through www and to each node's own address, and they verify
the chain against the lab CA. While they run, the grader runs your
`rotate.sh`. It passes only if every connection succeeded and both nodes
present the new certificate afterwards.

## Try it yourself

```
for ip in 172.29.22.11 172.29.22.12; do
  openssl s_client -connect $ip:443 -servername www </dev/null 2>/dev/null | openssl x509 -noout -serial -startdate
done
openssl x509 -in /ha/certs/www.pem -noout -serial -startdate
curl --cacert /ha/certs/ca.pem https://www/
```

<details>
<summary>Hint 1 — who reads the file</summary>

HAProxy reads `crt` files when it starts and when it reloads. It does not
watch them. Writing a new file changes nothing on any node until that node's
HAProxy loads it. Two HAProxy processes means two in-memory copies, and the
address in front of them does not affect which copy either one holds.

</details>

<details>
<summary>Hint 2 — load it without dropping anyone</summary>

There are two ways to load a new certificate without a restart.

- Reload: `touch /ha/<node>/start-haproxy` makes the node's supervisor send
  HAProxy `USR2`. In master-worker mode, new workers take over the
  listening sockets and old workers finish their connections, so nobody is
  refused.
- The runtime API: `set ssl cert` followed by `commit ssl cert` on the
  node's admin socket replaces the certificate in place.

Either way, check each node's own address afterwards. A check through www
only ever reaches one of them.

</details>

<details>
<summary>Solution</summary>

```
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
```

### The VIP moves an address, not a state

A VIP makes two machines look like one to clients. It does not make them
one machine. Everything a node holds in memory stays on that node: its
certificate, its configuration, its runtime changes. Each of those has to
be applied on every node. Moving the address only changes which copy
clients get, so after a failover they get whatever the standby node had
loaded.

That makes the standby the risky node. Nothing exercises it until the
moment it is needed. An expired certificate on the standby turns a routine
failover into an outage. A rotation that checks only through the VIP checks
the active node and nothing else. Monitor certificate expiry on each node's
own address. A renewal is not finished until every node presents the new
certificate.

</details>
