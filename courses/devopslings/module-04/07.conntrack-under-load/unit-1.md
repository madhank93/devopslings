---
title: "the connection tracker is filling up and nothing is connecting"
---

## The situation

The box refuses new connections during the afternoon peak. It is not short of
CPU, memory, file descriptors or worker threads. `dmesg` has this:

```
nf_conntrack: table full, dropping packet
```

And the table is genuinely full — of a service that opens no connections at all.

```
$ cat /proc/sys/net/netfilter/nf_conntrack_count
1247
$ /opt/metrics/ship.py 2000
sent=2000
$ cat /proc/sys/net/netfilter/nf_conntrack_count
3247
```

The metrics shipper sends fire-and-forget UDP: one packet per metric, a fresh
source port each time, no reply expected and none sent. Two thousand packets that
were over the instant they were sent leave two thousand entries behind, each held
for five minutes.

## Your objective

Make a 2000-packet burst cost fewer than 200 conntrack entries, with the
collector still receiving the metrics. Do not stop the shipper and do not stop
the collector — the traffic is wanted.

## What you're being graded on

Both services still running, a fresh 2000-packet burst creating under 200
entries, and the collector still receiving around 2000 of them.

<details>
<summary>Hint 1 — look at what is in there</summary>

```
$ conntrack -L | head
udp 17 299 src=10.67.0.1 dst=10.67.0.5 sport=51923 dport=9125 [UNREPLIED] ...
udp 17 299 src=10.67.0.1 dst=10.67.0.5 sport=51924 dport=9125 [UNREPLIED] ...
udp 17 299 src=10.67.0.1 dst=10.67.0.5 sport=51925 dport=9125 [UNREPLIED] ...
```

`[UNREPLIED]`, 299 seconds left, one per source port. The kernel is holding
state for a conversation that had one packet in it and will never have another.

</details>

<details>
<summary>Hint 2 — why is it tracking this at all?</summary>

Connection tracking exists to answer two questions: is this packet part of a flow
I already allowed, and how do I un-translate its reply. Both matter for NAT and
for stateful firewalling.

This traffic needs neither. There is no reply to un-translate and no stateful
rule to satisfy. The tracking is pure cost.

So the question is not how to make the entries expire faster. It is how to stop
creating them.

</details>

<details>
<summary>Hint 3 — before the entry exists</summary>

A rule in an ordinary filter chain runs *after* conntrack has already looked the
packet up and allocated for it. To opt out you have to get in front of that,
which is what the raw hooks are for:

```
nft 'add chain ip mytable out { type filter hook output priority -300 ; }'
```

Priority −300 is `raw` — ahead of conntrack at −200. The verdict you want there
is `notrack`.

Two hooks matter: `output` for packets this box originates, `prerouting` for
packets it forwards.

</details>

## Why this fills up

Conntrack keys on the five-tuple. A statsd client that opens a socket per metric
gets a fresh ephemeral source port per metric, so every packet is a brand new
flow by definition. There is no reuse to exploit.

Then the retention: an unreplied UDP flow is held for `nf_conntrack_udp_timeout`,
which is 30 seconds by default and set to 300 on this box, as gateways often are
after somebody tuned them for long-lived sessions years ago.

At a modest 200 metrics/second and a 300-second timeout, the steady state is
60,000 entries for a service that has no connections.

And the failure mode is brutal: once the table is full, the kernel drops the
packets that would have created new entries. That includes the SYN of every
genuine inbound connection. **A box doing nothing stops accepting work**, and the
symptom — connection refused, at random, under load — points at everything except
the metrics agent.

## The fix

<details>
<summary>Solution</summary>

Tell the kernel this traffic does not need tracking, before it allocates
anything:

```
$ nft add table ip rawtrack
$ nft 'add chain ip rawtrack out { type filter hook output     priority -300 ; }'
$ nft 'add chain ip rawtrack pre { type filter hook prerouting priority -300 ; }'
$ nft add rule ip rawtrack out ip daddr 10.67.0.5 udp dport 9125 notrack
$ nft add rule ip rawtrack pre ip daddr 10.67.0.5 udp dport 9125 notrack
$ conntrack -D -p udp --dport 9125
```

`notrack` is not a drop. The packets are forwarded and delivered exactly as
before; they simply stop being remembered. The last line clears what has already
accumulated, so the effect shows up now instead of in five minutes.

Both hooks are needed because packets the box *originates* pass `output` and
packets it *forwards* pass `prerouting`, and a metrics agent may well do both.

</details>

## The two answers that are not the answer

**Lower `nf_conntrack_udp_timeout`.** Real, and worth doing — 300 seconds for
unreplied UDP is indefensible. But it shrinks the damage rather than stopping it:
every packet still allocates an entry, still takes the lock, still costs the
insert. It buys headroom, not a fix.

**Raise `nf_conntrack_max`.** The reflex, and it trades memory for time. Each
entry is roughly 300 bytes, so a million entries is about 300 MB of kernel memory
held for traffic nobody is tracking on purpose. It also makes the eventual
failure bigger and later.

On this box you cannot do it anyway: `nf_conntrack_max` is exposed read-only
outside the initial network namespace, so a container can read the ceiling and
never raise it. That constraint is worth knowing before an incident, not during.

## A trap worth carrying

```
$ sysctl -w net.netfilter.nf_conntrack_max=65536
sysctl: setting key "net.netfilter.nf_conntrack_max": Operation not permitted
$ echo $?
0
```

It prints the error and **exits zero**. Any script that trusted the exit status
would report success. Read the value back after writing it.

## Carrying this forward

**Ask what the state is for.** Tracking exists to serve NAT and stateful rules.
Traffic that needs neither is paying rent for nothing.

**Untracked is not dropped.** `notrack` changes bookkeeping, not delivery — which
is why the check here confirms the metrics still arrive. A rule that "fixed" the
count by discarding the traffic would look identical in the counter.

**A full table breaks the things that are innocent.** The conntrack ceiling is
shared by everything on the box. The service that fills it and the service that
fails are usually not the same service.
