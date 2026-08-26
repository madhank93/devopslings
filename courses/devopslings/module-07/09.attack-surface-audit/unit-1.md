---
title: "the internal API that was answering the whole internet"
---

## The situation

Two services listen on this box. Before reasoning about who might attack it, the
first question of any threat model is simpler and more concrete: what does this
machine expose, and to whom? Every listening port is a door. So enumerate them:

```
$ ss -ltnp
State   Recv-Q  Local Address:Port   Process
LISTEN  0       0.0.0.0:80           python3  (portal.service)
LISTEN  0       0.0.0.0:9000         python3  (metrics-api.service)
```

Two doors. Now the question that matters for each: who is supposed to be able to
open it?

- **Port 80** is the customer portal. It is *meant* to face the internet —
  `0.0.0.0` is correct here, because the whole point is that anyone can reach it.
- **Port 9000** is the internal metrics API. It reports CPU, memory and disk, and
  it has no authentication, because whoever wrote it assumed it would only ever
  be read from the box itself. It is also on `0.0.0.0`.

Those two facts about port 9000 — no authentication, and listening on every
interface — are fine individually and a breach together. An unauthenticated
endpoint is acceptable when only the box can reach it. A service on every
interface is acceptable when it authenticates. This one is neither: it answers
system telemetry to anyone who can route to the host.

```
$ curl -s http://<the box's LAN address>:9000/
metrics: cpu=3% mem=41% disk=55%
```

That is the attack surface nobody meant to create. It was not opened by an
attacker or a bad password; it was opened by a default bind address and an
assumption that never got checked.

## Intended exposure is the whole audit

The mental tool here is *intended* exposure versus *actual* exposure. For every
listener, write down who should reach it, then check who actually can. The two
match for port 80 and diverge for port 9000, and the divergence is the finding.
This is not a fancier technique than looking at `ss` output — it is looking at
`ss` output and asking a question about each line that people skip because the
service "works."

The fix follows directly from the intent. Port 9000 should be reachable only
from the box, so bind it to the loopback interface:

```
$ cat /etc/metrics/bind.conf
127.0.0.1:9000
$ sudo systemctl restart metrics-api
$ ss -ltn | grep 9000
LISTEN  0  127.0.0.1:9000
```

Now the local reader that consumes the metrics still works, and the network
cannot see the endpoint at all. Nothing about the service's missing
authentication changed — but it no longer needs it, because the interface it
listens on is one only the host can talk to. Reducing exposure and adding a
control are two ways to close the same gap; here, exposure was the cheaper and
more complete one.

## Do not over-correct

The opposite mistake is as real as the first. Port 80 is on `0.0.0.0` for a
reason, and "lock down everything on all interfaces" would take the customer
portal off the internet — an outage caused by security tidying. The audit is not
"bind everything to loopback"; it is "bind each thing to the smallest exposure
its purpose actually requires." For the portal that is the whole internet; for
the metrics API it is the loopback interface. Least exposure means least *for its
job*, not least in general.

This is the shape of every attack-surface reduction: the win is closing the doors
nobody meant to open while leaving the ones the system needs. Getting there is
one boring pass over the listeners, asking of each the question the original
author forgot to.

<details>
<summary>Hint 1 — enumerate and classify</summary>

```
$ ss -ltnp
```

Two listeners. One is meant to be public (the portal), one is meant to be
internal (the metrics API). Both are on `0.0.0.0`. Only one of those is wrong.

</details>

<details>
<summary>Hint 2 — restrict the internal one to loopback</summary>

The metrics API reads its bind address from `/etc/metrics/bind.conf`. Change it
from `0.0.0.0:9000` to `127.0.0.1:9000` and restart:

```
$ echo '127.0.0.1:9000' | sudo tee /etc/metrics/bind.conf
$ sudo systemctl restart metrics-api
```

</details>

<details>
<summary>Hint 3 — leave the portal alone</summary>

Port 80 is public by design. Do not restrict it — restricting the thing that is
supposed to be reachable is its own outage. Confirm both:

```
$ ss -ltn | grep -E ':80|:9000'
$ curl -s http://127.0.0.1/          # portal up
$ curl -s http://127.0.0.1:9000/     # metrics, from the box only
```

</details>

## Checking yourself

```
$ ss -ltn | grep -E ':80|:9000'
LISTEN 0  0.0.0.0:80
LISTEN 0  127.0.0.1:9000
```

The portal answers the world; the metrics API answers only the box.

<details>
<summary>Solution</summary>

```bash
# Restrict the internal metrics API to loopback; leave the public portal alone.
echo '127.0.0.1:9000' | sudo tee /etc/metrics/bind.conf
sudo systemctl restart metrics-api.service
```

```
port_80: public
port_9000: internal
overexposed_port: 9000
restricted_to: 127.0.0.1
```

</details>
