---
title: "one upstream is slow for one client, sometimes"
---

## The situation

`payments-client` calls two upstreams in a loop: `ledger-api` on
`10.81.1.2:8080` and `fx-rates` on `10.81.2.2:8080`. Most calls take a few
milliseconds. Now and then one takes a second, or three. Every other service
is fine.

The first guess is to ping the upstreams:

```
$ ping -c 20 -q 10.81.2.2
20 packets transmitted, 20 received, 0% packet loss, time 19030ms
rtt min/avg/max/mdev = 0.041/0.067/0.112/0.017 ms
```

The RTT is normal, and twenty pings at a few percent loss often lose nothing.
Even a ping that does show `3% packet loss` reads as small. It is not small to
TCP: a lost segment is noticed only when a timer runs out, and the first
retransmission timeout is at least 200 ms and doubles on each miss. Three
percent of packets becomes a large share of slow calls, and the stall is
measured in timeouts, not RTTs.

## Your objectives

- Name the peer the retransmits are with, from `tcpretrans.bt`
- Find what is losing packets on that path, and remove it, leaving the upstream
  running
- Write `/root/answers/retrans.md`:

```
peer: <address of the upstream the retransmits are with>
cause: <what was dropping packets, and where>
```

## What you're being graded on

- `peer` is the right upstream, and `cause` names what dropped packets and
  where it sat
- no `netem` qdisc is left anywhere on that path — a smaller loss is still loss
- the grader makes 40 calls to that upstream: all succeed, and the kernel's
  `TcpRetransSegs` counter does not move

<details>
<summary>Hint 1 — the tool</summary>

```
/usr/sbin/tcpretrans.bt
```

One line per retransmitted segment, with both ends of the connection. Ten
seconds is plenty.

</details>

<details>
<summary>Hint 2 — the path has two ends</summary>

`tc qdisc show` on the box shows the box's side. Each upstream runs in its own
network namespace (`ip netns list`), with its own interfaces and its own
qdiscs: `ip netns exec <ns> tc qdisc show`.

</details>

<details>
<summary>Hint 3 — deleting a qdisc</summary>

`tc qdisc del dev <if> root` puts the interface back on its default queue.

</details>

## Seeing retransmits

The kernel counts them:

```
$ nstat -az TcpRetransSegs
TcpRetransSegs                  1834               0.0
```

That proves they happen, not where. `tcpretrans.bt` puts a kprobe on the
kernel's retransmit function and prints each one with its connection:

```
$ /usr/sbin/tcpretrans.bt
Attaching 3 probes...
Tracing tcp retransmits. Hit Ctrl-C to end.
TIME     PID               LADDR:LPORT           RADDR:RPORT  STATE
10:21:03 0           10.81.2.2:8080          10.81.2.1:51234  ESTABLISHED
10:21:04 0           10.81.2.2:8080          10.81.2.1:51262  ESTABLISHED
10:21:06 0           10.81.2.2:8080          10.81.2.1:51310  ESTABLISHED
```

Every line names `10.81.2.2:8080`, and `ledger-api` never appears. Look at
which side it is on: `LADDR` is the end that *retransmitted*. The client sends
a short request; the upstream sends 256 KB back, so most segments that get
lost are the upstream's, and the upstream is the one resending them. The kprobe
is in the kernel, which is shared by every namespace on the box, so it sees
those retransmits even though they happen in the upstream's namespace.

The box is a container, so "the kernel" is the host's: retransmits from other
containers on the same machine show up too. Read the addresses, and keep the
lines on `10.81.x.x`.

libbpf-tools has no `tcpretrans`; the bpftrace script is the tool here.
`tcplife` adds the other half — each connection's lifetime and bytes as it
closes — which ties a slow call to the connection that retransmitted:

```
tcplife -D 8080 | grep 10.81.
```

Its `PID` column is the host's PID, not the one `ps` shows inside the box, so
match connections by address, not by PID.

`PID 0` on the retransmit lines is expected: retransmits fire from a timer, in
interrupt context, not from any process.

## Finding the loss

`tc` on the box shows nothing unusual on `pay-fx`. The upstream's side of the
link is in its namespace:

```
$ ip netns list
fx-rates (id: 1)
ledger-api (id: 0)
$ ip netns exec fx-rates tc qdisc show dev eth0
qdisc netem 8001: root refcnt 2 limit 1000 loss 3%
```

`netem` is the kernel's network emulator: it adds delay, loss, duplication or
reordering on purpose. Someone ran a failure test against `fx-rates` and left
it in place. On a real network the same evidence — retransmits to one peer,
nothing to the others — points at that peer's NIC, a switch port, a duplex
mismatch or a congested link, and the next step is that hop's error counters.

Removing it:

```
ip netns exec fx-rates tc qdisc del dev eth0 root
```

Setting the loss to `0%` or `0.1%` leaves the emulator in the path; deleting
the namespace takes the upstream with it. Neither passes.

## Checking yourself

```
a=$(ip netns exec fx-rates nstat -az TcpRetransSegs | awk '/Retrans/{print $2}')
for i in $(seq 40); do curl -s -o /dev/null http://10.81.2.2:8080/quote.bin; done
b=$(ip netns exec fx-rates nstat -az TcpRetransSegs | awk '/Retrans/{print $2}')
echo $((b - a))
```

<details>
<summary>Solution</summary>

```
/usr/sbin/tcpretrans.bt          # every line: 10.81.2.2:8080
ip netns exec fx-rates tc qdisc show dev eth0
ip netns exec fx-rates tc qdisc del dev eth0 root
```

```
peer: 10.81.2.2
cause: netem loss 3% on eth0 inside the fx-rates network namespace
```

</details>
