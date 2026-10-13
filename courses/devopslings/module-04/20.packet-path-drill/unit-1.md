---
title: "the storefront cannot get its orders, and every layer says it is fine"
---

## The situation

```
$ shop-probe
shop-probe: 50 lookups of orders.internal:8080 at once, 750ms budget each
  ok 0/50   slowest 2.01s
    50  timed out                                2.01s-2.01s
```

The storefront's order lookups are missing their 750ms budget. orders is up,
`ss` says it is listening, and its journal says nothing at all. That is the
entire ticket, and it will be the entire ticket every time you run this lesson —
because the fault is drawn at random from five, and each lives at a different
place on the path a packet takes through this box.

The storefront (10.72.0.6) and orders (10.72.0.5) are network namespaces on one
bridge, `br-shop`. The storefront looks up `orders.internal`, which `/etc/hosts`
says is 203.0.113.20 — an address on this box that a DNAT rule rewrites to
orders. So every lookup goes in through the bridge, is translated, is routed,
and goes back out the same bridge. Everything that decides how is boot
configuration: `/etc/sysctl.d/`, and the routes, NAT table and orders-namespace
sysctls in `/etc/shopnet/`, which `shopnet.service` applies.

The journal also has `lb-health` reporting orders DOWN every fifteen seconds.

You cannot memorise the answer. You can memorise the order you follow the
packet in.

## Your objectives

- Make `shop-probe` pass — all 50 lookups inside 750ms — by repairing the
  configuration that was broken, so it survives a reboot
- Write `/root/answers/triage.md`, three lines:

  ```
  cause:     <what was wrong, in a few words>
  evidence:  <the command or counter that proved it>
  detection: <a signal and a threshold that would have paged first>
  ```

## What you're being graded on

The check first runs `shop-probe` against what you left running. Then it does
what a boot would: sets `ip_forward` and orders' `somaxconn` back to the
kernel's defaults, re-applies `/etc/sysctl.d`, restarts `shopnet.service` and
`orders.service`, and runs `shop-probe` again. That is the measurement that
counts. A fix that only lives in the running kernel — `sysctl -w`, `ip route
del`, `nft add rule` — passes the first run and fails the second, and the check
says so.

It also refuses the repairs that make the symptom go away by going around it:

- **orders.internal stays 203.0.113.20** for IPv4, from the storefront — no
  pointing it straight at orders, no `/etc/netns` override
- **any AAAA the name has must answer**, and the dual-stack rollout is not being
  rolled back: no deleting the record, no turning IPv6 off, no `gai.conf`
- **`bridge-nf-call-iptables` stays off**, the publication stays, the default
  route and the other static route stay, and no nftables table appears that
  boot would not load
- **the CIS baseline keeps its other controls**
- **orders, its config, the probe, `shopnet-up` and `lb-health` are unchanged**,
  and `lb-health` is still running

And `triage.md`: `cause` must describe the fault that was seeded (and only that
one); `evidence` must be the command or counter that proves it; `detection` must
name a signal that fits it *and* a number.

<details>
<summary>Hint 1 — follow one lookup</summary>

Read the probe's output before anything else. *How* the lookups fail — all
timing out at the connect timeout, some arriving just after a second, all
succeeding late over one family — already rules most of the path out.

```
$ ip netns exec storefront getent ahosts orders.internal   # every address, both families
$ sysctl net.ipv4.ip_forward                                # will this box route at all?
$ ip route get 10.72.0.5                                    # which route wins, not which exist
$ ip netns exec orders ss -lnt 'sport = :8080'              # Send-Q is the granted backlog
$ ip netns exec orders nstat -az TcpExtListenOverflows
$ tcpdump -ni br-shop 'port 8080'                           # who answers whom
```

1. What does the name resolve to, and does every address answer?
2. Does the box forward?
3. Which route does the kernel pick for orders?
4. Can the listener hold a burst?
5. Does the reply come back through the box that translated the request?

</details>

<details>
<summary>Hint 2 — reading what the probe says</summary>

- **timed out at 2.0s, every one**: nothing ever came back. The SYN went
  somewhere it died — or came back somewhere it was not expected.
- **over budget at 1.0–1.3s, some ok**: a dropped SYN, retransmitted after
  the kernel's initial one-second timeout. Something dropped *some* of a burst.
- **over budget at ~2.0s, connected over ipv4**: the first address tried did
  not answer, the client waited out its whole connect timeout, then fell back.

</details>

<details>
<summary>Hint 3 — where each piece of configuration lives</summary>

`sysctl.d` files apply in filename order, and a later file wins. `ip route`
picks the longest matching prefix, whatever the order of the file. `somaxconn`
is per network namespace, and the kernel grants `min(backlog, somaxconn)`.
A DNAT'd connection from a client on the same subnet as the server needs its
source rewritten too, or the server answers the client directly.

</details>

## What actually happened

| Fault | What was changed | What the probe shows | The tell |
|---|---|---|---|
| route | `/etc/shopnet/routes` gained `10.72.0.0/28 via 172.31.0.99` | 50 timed out | `ip route get 10.72.0.5` picks the dead gateway over `br-shop`'s /24 |
| forward | `60-cis-network.conf` gained `net.ipv4.ip_forward = 0`, sorting after `30-shop-router.conf` | 50 timed out | `ip_forward` is 0; `IpInAddrErrors` climbs as lookups arrive |
| hairpin | `nat.nft` lost the masquerade for the segment's own lookups | 50 timed out | orders' SYN-ACK goes straight to 10.72.0.6, which resets it; conntrack sits in `SYN_SENT` |
| ipv6 | `/etc/hosts` gained a AAAA, `fd00:72:1::5`, that nothing holds | all late at ~2.0s, over ipv4 | `getent ahosts` lists it; nothing answers there |
| backlog | `orders.sysctl` gained `net.core.somaxconn = 8` | a few ok, most late at ~1s | `ss -lnt` shows Send-Q 8; `ListenOverflows` climbs |

The red herring, every run: `lb-health` logs `orders 10.72.0.5:8081 DOWN
(Connection refused)`, and a capture on the bridge is full of resets. It is the
retired edge balancer's health check, aimed at a port orders stopped listening
on. A reset is a host saying nothing listens on that port — which is true, and
is about :8081. The storefront's traffic is on :8080.

<details>
<summary>Solution</summary>

Repair the one thing, in the file that sets it, then make the running system
match.

```bash
# route: delete the stale line, re-apply
#   sed -i '/^10\.72\.0\.0\/28 /d' /etc/shopnet/routes && systemctl restart shopnet

# forward: the router's exception must sort after the baseline it overrides
#   mv /etc/sysctl.d/30-shop-router.conf /etc/sysctl.d/90-shop-router.conf
#   sysctl -p /etc/sysctl.d/90-shop-router.conf

# hairpin: put the masquerade back in the postrouting chain of nat.nft
#   ip saddr 10.72.0.0/24 ip daddr 10.72.0.5 tcp dport 8080 ct status dnat masquerade
#   systemctl restart shopnet

# ipv6: point the AAAA at the address orders actually holds
#   ip netns exec orders ip -6 addr show scope global      # fd00:72::5
#   (rewrite /etc/hosts in place — it is a bind mount)

# backlog: a somaxconn that fits the backlog orders asks for, then restart it
#   net.core.somaxconn = 4096  in /etc/shopnet/orders.sysctl
#   systemctl restart shopnet orders
```

Then, for example:

```
cause: 60-cis-network.conf sets ip_forward = 0 and sorts after the router's own file
evidence: sysctl net.ipv4.ip_forward = 0; IpInAddrErrors climbing in nstat
detection: ip_forward != 1 on a box that routes, or IpInAddrErrors > 0 per minute
```

</details>

## Carrying this forward

- **Read how it fails before where.** A connect timeout, a one-second
  retransmit and a family fallback are three different places on the path, and
  the probe told you which before you ran anything else.
- **Ask the kernel what it decided, not what it was told.** `ip route get`,
  `sysctl -n`, the listener's Send-Q, the conntrack reply tuple.
- **The fix lives where boot reads it.** Every one of these had a working
  runtime fix that the next reboot would undo.
- **A reset is an answer.** Something that says no, immediately, is rarely what
  is making the other thing time out.

Run the lesson again. The fault moves, and the questions do not.
