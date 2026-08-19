---
title: "the small requests all work, and the one that matters hangs forever"
---

## The situation

CI cannot publish build artifacts to the store at `10.90.2.9:8080`. Two days of
it. Everything anyone has tried in order to prove the host is fine has proved
the host is fine:

```
$ curl -s http://10.90.2.9:8080/
artifact-store-2026

$ curl -s -o /dev/null -w '%{size_download}\n' http://10.90.2.9:8080/blob
1000000

$ ping -c2 10.90.2.9
2 packets transmitted, 2 received, 0% packet loss
```

The health check passes. A 1 MB **download** from that host completes. And this
hangs until the client gives up:

```
$ curl -s -m 10 --data-binary @/root/artifact.bin http://10.90.2.9:8080/upload
curl: (28) Operation timed out after 10001 milliseconds with 0 bytes received
```

Same host. Same port. Same connection, opened successfully. One megabyte down
works and one megabyte up does not.

The store logs nothing for the failed upload, because from its point of view
nothing arrived. Nobody has touched a firewall on either end, and that is true —
there is no rule anywhere that blocks port 8080.

## What is actually broken

Every host on this path is configured correctly for the link it can see:

```
                        ---- 1400 --->
box ---- 1500 ---- r1                   r2 ---- 1500 ---- far
                        <--- 1500 ----
```

This box sits on a 1500-byte link, so it offers a 1460-byte MSS. The store sits
on a 1500-byte link, so it offers a 1460-byte MSS. They agree. Neither of them
has any way to know about the 1400-byte link in the middle, and they are not
supposed to.

The router that *does* know is supposed to say so. When `r1` gets a 1500-byte
packet with the don't-fragment bit set and can only forward 1400, it is required
to drop the packet and send back an ICMP `destination-unreachable /
fragmentation-needed` carrying the MTU it *can* forward. The sender lowers its
estimate for that destination and retransmits smaller. That exchange is **path
MTU discovery**, and it is the only thing holding the arrangement together.

Take that one message away and you get a black hole:

| | |
|---|---|
| The connection opens | handshake packets are tiny |
| Small requests work | they fit in one small segment |
| Health checks pass | also tiny |
| `ping` works | 84 bytes |
| `traceroute` works | tiny probes |
| Anything that fills a segment | **vanishes, forever, silently** |

No refusal. No reset. No timeout on connect. No log line. The sender keeps
retransmitting a packet that cannot fit, at the size that cannot fit, until the
application above it gives up.

## Why downloads work and uploads do not

This sounds impossible on one TCP connection, and it is not. **The tunnel's two
ends disagree about their MTU** — 1400 leaving the near end, 1500 leaving the
far end. Somebody sized one end for the encapsulation overhead and left the
other at the default, which is one of the most common tunnel bugs there is.

So there is exactly one narrow direction on this path. Traffic from the store
towards you is never squeezed by anything and arrives whole. Traffic from you
towards the store hits a wall at the first router, and the message that would
have told you so is dropped.

Read the asymmetry as evidence. It rules out reachability, it rules out the
service, it rules out anything port-based — and it points at one link, in one
direction. "Which way is broken?" is a question worth asking early, and almost
nobody asks it.

There is a second-order effect here worth knowing, because it is how this class
of fault hides from you: if the return direction *were* also squeezed, the store
would be told the path MTU by the router squeezing it, and it would then start
advertising a 1360-byte MSS on every new connection. That caps what your box
sends, and your upload would begin working — by accident, for a reason nobody
could name, after the first large download. MTU faults that come and go are
usually this.

## Your objective

Make the upload complete. It must report the full 1048576 bytes:

```
$ curl -s -m 25 --data-binary @/root/artifact.bin http://10.90.2.9:8080/upload
stored bytes=1048576
```

Then write `/root/answers/mtu.md`, exactly two lines:

```
path_mtu: <bytes>
largest_df_payload: <bytes>
```

`path_mtu` is the largest packet that can cross the whole path to `10.90.2.9`.
`largest_df_payload` is the largest ICMP echo payload that survives the trip with
fragmentation forbidden — the number you measure to get the first one.

The link between `10.90.0.2` and `10.90.1.2` is a tunnel run by another team.
**Its MTU must still be what it is now when you are finished.** Widening it makes
the symptom disappear and is not available to you: the encapsulation overhead
that made it 1400 is real, and a real tunnel would start dropping again.

## What you're being graded on

The upload completing, the small request and the 1 MB download still working, the
traffic still going via `10.90.0.2`, the tunnel still 1400 bytes wide, and both
numbers in the answer file correct.

<details>
<summary>Hint 1 — measure the path, do not read it</summary>

The thing that would have told you what is wrong is the thing that is missing, so
send packets of a known size and see which ones come back:

```
$ ping -M do -s 1372 -c1 10.90.2.9
$ ping -M do -s 1373 -c1 10.90.2.9
```

`-M do` sets don't-fragment, so a packet too big to forward is dropped rather
than cut up. `-s` is the **payload**, not the packet. Bisect `N` between 1 and
1472 and find the largest one that still gets a reply.

Note what you do *not* get when the packet is too big: not an error, not
"Frag needed and DF set". Silence. That silence is the diagnosis.

</details>

<details>
<summary>Hint 2 — from payload to MTU</summary>

An ICMP echo goes out wrapped in an 8-byte ICMP header and a 20-byte IP header:

```
packet = payload + 8 (ICMP) + 20 (IPv4)  =  payload + 28
```

So the largest payload that survives, plus 28, is the largest packet the path
will carry. That number is the path MTU, and it is not 1500.

`tracepath 10.90.2.9` is worth running too, for the contrast: it reports what it
can and cannot tell you here.

</details>

<details>
<summary>Hint 3 — where the message is being lost</summary>

The routers on this path are namespaces on this box, so you can look inside them:

```
$ ip netns list
$ ip netns exec r1 ip -br addr
$ ip netns exec r1 nft -a list ruleset
$ ip netns exec r2 nft -a list ruleset
```

One of the two has a rule the other does not. It does not mention port 8080, it
does not mention TCP, and it is why this box never learned anything.

Compare `ip netns exec r1 ip link show r1-r2` with your own `ip link show to-r1`
while you are in there. The MTU difference is the fact the endpoints cannot see.
Then look at `ip netns exec r2 ip link show r2-r1` — the *other end of the same
link* — and notice it does not match either.

</details>

<details>
<summary>Hint 4 — three ways to fix it, one of them right</summary>

- Stop the message being dropped.
- Tell this box the answer by hand: `ip route change 10.90.2.0/24 via 10.90.0.2
  dev to-r1 mtu 1400`.
- Clamp the MSS — but read the next paragraph first, because the obvious way to
  do it does not work here.

All three make the upload complete. Only one of them fixes the *reason*.

**On clamping, since almost everyone gets this backwards.** The MSS option in a
SYN says *"this is the largest segment I am willing to receive"*. So clamping
your own outgoing SYN changes what the store sends **to** you, and does nothing
whatever about the upload:

```
# looks right, fixes nothing here
nft add rule inet mtufix postrouting oifname to-r1 \
    tcp flags syn tcp option maxseg size set 1360
```

To limit what *you* send, you have to shrink the number the far end advertises
to you — clamp the SYN-ACK on the way in:

```
nft add table inet mtufix
nft 'add chain inet mtufix prerouting { type filter hook prerouting priority mangle ; policy accept ; }'
nft 'add rule inet mtufix prerouting iifname to-r1 tcp flags syn tcp option maxseg size set 1360'
```

Routers in the middle of a path clamp both directions at once, which is why the
rule you find on the internet looks symmetric and why copying it onto an
endpoint quietly does half of nothing.

</details>

## Why anyone blocks this ICMP

Nobody blocks fragmentation-needed on purpose. It gets blocked as collateral, and
almost always one of these three ways:

- **"ICMP is a security risk."** Someone drops ICMP wholesale at a perimeter,
  having been taught that ping is an information leak. Echo request and echo
  reply are the ones they meant. Type 3 code 4 is load-bearing and goes with it.
- **A stateful firewall with no related-state.** The ICMP error comes from a
  router in the middle, not from the destination, so a ruleset that only accepts
  `ct state established,related` on a path where conntrack cannot associate the
  error will drop it.
- **A tunnel endpoint that cannot generate it.** Some encapsulators silently drop
  oversized packets instead of reporting them, which is the same outcome with
  nobody to blame.

This is why every overlay network you will meet clamps MSS rather than trusting
the mechanism. Kubernetes CNIs, WireGuard configs, PPPoE routers, IPsec
gateways — all of them carry an MSS clamp, and the reason is that path MTU
discovery is one dropped packet type away from a black hole and the people
dropping it will never know they did.

## What actually happened

One rule, in the router at the near end of the tunnel:

```
$ ip netns exec r1 nft -a list ruleset
table inet tunnel {
  chain output {
    type filter hook output priority filter; policy accept;
    icmp type destination-unreachable icmp code 4 drop # handle 2
  }
}
```

Note that `nft` prints the code back as the number `4`, whoever wrote it and
whatever name they used. Code 4 of type 3 is fragmentation-needed, and you will
meet it written both ways.

Note where it is: the **output** chain of `r1`, not a forward chain. The packets
being blocked are not your traffic. They are the router's own attempts to explain
itself.

<details>
<summary>Solution</summary>

Measure first:

```
$ ping -M do -s 1472 -c1 10.90.2.9      # silence
$ ping -M do -s 1372 -c1 10.90.2.9      # reply
1380 bytes from 10.90.2.9: icmp_seq=1 ttl=62 time=0.09 ms
```

1372 + 28 = **1400**. That is the path MTU.

Then delete the rule that suppressed the message, by handle, leaving the rest of
the ruleset alone:

```
$ handle=$(ip netns exec r1 nft -a list chain inet tunnel output \
           | grep destination-unreachable \
           | sed -n 's/.*# handle \([0-9]*\)$/\1/p')
$ ip netns exec r1 nft delete rule inet tunnel output handle "$handle"
$ ip route flush cache
```

The next large upload now works, and it works because this box was *told*:

```
$ curl -s -m 25 --data-binary @/root/artifact.bin http://10.90.2.9:8080/upload
stored bytes=1048576

$ ip route get 10.90.2.9
10.90.2.9 via 10.90.0.2 dev to-r1 ... mtu 1400
```

That `mtu 1400` on a route nobody configured is path MTU discovery having
happened. It is the whole mechanism, visible in one line.

```
path_mtu: 1400
largest_df_payload: 1372
```

</details>

## Carrying this forward

- **A working `ping` proves the path carries 84 bytes.** Nothing more. Every
  reflex tool for "is the network fine" is small, and MTU faults are invisible to
  all of them.
- **"Small works, large hangs" is an MTU story** until proven otherwise. It is not
  a slow server, and no timeout you raise will help — the packet is not late, it
  is gone.
- **Asymmetric failure is a gift.** Up broken and down fine narrows a fault to
  one direction of one link before you have logged into anything.
- **When you build a tunnel, clamp the MSS.** Not because the ICMP is broken
  today, but because you will never be told when it is.

The next lesson keeps the packets small enough and the path clear, and breaks the
handshake that happens before any of your bytes are sent — a certificate that
`curl -k` will accept and a client library never will.
