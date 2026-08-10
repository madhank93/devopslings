---
title: "one capture, three connections, three different failures"
---

## The situation

Three connections to the same host. All three came back to the on-call engineer
as "it timed out". One of them was not a timeout at all, and the other two have
nothing in common except the word.

The capture is at `/root/capture.pcap`.

```
$ tcpdump -r /root/capture.pcap -nn
```

## Your objective

For each flow, decide what the packets show and which end has to change
something. Write the answers into `/root/answers/capture.md`.

```
flow-9301: verdict=? fault=?
flow-9302: verdict=? fault=?
flow-9303: verdict=? fault=?
```

`verdict` is one of `retransmission`, `reset`, `zerowindow`. `fault` is one of
`client`, `server`, `network` — meaning which end has to change something, not
which end sent the last packet.

## What you're being graded on

Three correct verdicts and three correct faults. Nothing needs configuring.

<details>
<summary>Hint 1 — read one flow at a time</summary>

```
$ tcpdump -r /root/capture.pcap -nn 'port 9301'
$ tcpdump -r /root/capture.pcap -nn 'port 9302'
$ tcpdump -r /root/capture.pcap -nn 'port 9303'
```

Three questions per flow, in this order:

1. Did anything come back at all?
2. If so, how fast, and with which flag?
3. If data flowed, what happened to the `win` field over time?

</details>

<details>
<summary>Hint 2 — the flags</summary>

| tcpdump | meaning |
|---|---|
| `[S]` | SYN — opening |
| `[S.]` | SYN-ACK — accepted |
| `[.]` | bare ACK |
| `[P.]` | data |
| `[R]` `[R.]` | RST — refused or torn down |
| `[F.]` | FIN — orderly close |

`win N` is the receive window the **sender of that packet** is advertising: how
much more it is willing to accept right now.

</details>

<details>
<summary>Hint 3 — timing separates two of them</summary>

Look at the timestamps.

An answer that arrives in microseconds came from a machine that had already
decided. An answer that never arrives, while the same packet goes out at 1s, 2s,
4s, 8s, is TCP's exponential backoff — the sender talking to itself.

</details>

## Flow 9301 — nothing came back

```
09:27:32.174906 IP 10.90.0.1.43828 > 10.90.0.5.9301: Flags [S], seq 2529532845
09:27:33.190276 IP 10.90.0.1.43828 > 10.90.0.5.9301: Flags [S], seq 2529532845
09:27:34.214123 IP 10.90.0.1.43828 > 10.90.0.5.9301: Flags [S], seq 2529532845
09:27:35.237999 IP 10.90.0.1.43828 > 10.90.0.5.9301: Flags [S], seq 2529532845
```

The same SYN, same sequence number, at widening intervals, and **not one packet
in the other direction**.

That is a **retransmission** — the client doing its job correctly against
silence.

The fault is the **network**. Neither end misbehaved: the client sent a valid
SYN, and the server never saw it, so it could not have answered. Something in
the path discarded the packets and did not say so. A firewall with a `DROP` rule
rather than `REJECT`, a security group, a blackhole route.

The tell is the *absence*. A machine that received the SYN would have answered
something — SYN-ACK if it was listening, RST if it was not. Nothing at all means
nothing arrived.

## Flow 9302 — refused immediately

```
09:27:38.186282 IP 10.90.0.1.56434 > 10.90.0.5.9302: Flags [S], seq 3285537333
09:27:38.186304 IP 10.90.0.5.9302 > 10.90.0.1.56434: Flags [R.], seq 0, ack 3285537334, win 0
```

Two packets, 22 microseconds apart. A **reset**.

This is not a timeout and it never was. The application reported one because it
mapped every connection failure to the same message, which is how three
different faults arrived on the same ticket.

The far host behaved perfectly: it has no listener on 9302 and said so
immediately. That is what a healthy machine does with a connection to a closed
port.

The fault is the **client** — something is connecting to the wrong port, or to
the right port on the wrong host, or to a service that is not running and is
supposed to be. The reset is the answer, not the problem.

Note that the RST also carries `win 0`. It is meaningless there — the connection
is being destroyed, so there is no window to advertise. Read the flag first.

## Flow 9303 — the transfer stalled

```
09:27:38.227160 IP 10.90.0.5.9303 > 10.90.0.1.46648: Flags [.], ack 1449, win 0
09:27:38.438708 IP 10.90.0.5.9303 > 10.90.0.1.46648: Flags [.], ack 1449, win 0
```

The handshake completed, data flowed, and then the server started advertising
`win 0`. A **zero window**.

`win 0` means: *I have acknowledged everything you sent, my buffer is full, send
me nothing more until I say otherwise.* Flow control working exactly as designed.
The sender must stop, and it does, and the application on the sending side sees a
transfer that has gone quiet.

The fault is the **server**. The window belongs to the receiver, and it collapsed
because the application accepted the connection and then stopped reading from
it — a blocked worker, a full thread pool, a process stuck on a lock or on disk.

Note `ack 1449` repeating. It is acknowledging receipt while refusing more. The
network delivered everything. The application on the far side is the bottleneck,
and there is no faster network that fixes it.

## Solving it

<details>
<summary>Solution</summary>

```
flow-9301: verdict=retransmission fault=network
flow-9302: verdict=reset fault=client
flow-9303: verdict=zerowindow fault=server
```

</details>

## Carrying this forward

A capture answers "which end is at fault" faster than any log, because both ends
are in it.

| What you see | What it means |
|---|---|
| Repeated identical packets, no reply | discarded in the path — nobody received it |
| `[R]` immediately | received and refused — a decision was made |
| `[R]` mid-connection | one end tore down an established connection |
| `win 0` from the receiver | receiver's application is not reading |
| `[S]` then `[S.]` then nothing | handshake fine, application never got it (accept queue) |
| Duplicate ACKs, then a retransmit | genuine loss, and recovery working |

"It timed out" is what an application says when it has stopped waiting. It
describes the client's patience, not the failure. The packets describe the
failure.
