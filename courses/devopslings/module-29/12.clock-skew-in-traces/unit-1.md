---
title: "ledger answers seconds before checkout asks"
---

## The situation

checkout takes an order, records it with ledger, then ships it with fulfil.
Each app runs on a host of its own name, and sends its spans through the
Collector (`/obs/otel/collector.yaml`) to Tempo. Open a trace:

```
curl -s 'http://tempo:3200/api/search?q={name="POST /checkout"}&limit=3' | jq -r '.traces[].traceID'
```

In Grafana (`http://localhost:13000`, Explore, Tempo) the waterfall is
wrong: ledger's span starts seconds to the left of the client span that
called it, and is over before it began. fulfil's span, called a moment
later in the same request, sits inside its caller where it belongs.

The ticket filed against the tracing library says "context propagation
bug, spans attach to the wrong parent". Before agreeing, look at what the
trace actually tells you.

## A span's time is its host's clock

The trace context carries ids and flags, never time. Each span's start and
end are read from the clock of the host that recorded it — `time.time_ns()`
in this SDK — and Tempo draws them on one axis as if all those clocks agreed.

Within a host, they do, which is why ledger's own `INSERT entries` span sits
neatly inside ledger's server span. Across hosts they agree only as well as
the hosts' clocks do. A client span on host A and the server span it caused
on host B are bracketed by real events: B cannot receive the request before
A sends it. So when a child starts before its parent by the same amount in
every trace, and only across one pair of hosts, the propagation is fine and
a clock is not.

This is module 01's `clock-skew` seen from the trace side. On real hosts the
fix is time sync: `chronyc tracking` shows the offset, `chronyc makestep`
steps the clock, and a working NTP source keeps it there. In this lab the
hosts are emulated: `/obs/hosts/<host>/clock-offset` holds how far a host's
clock is off, in seconds, and writing `0` there is `chronyc makestep`.
Measure from a trace before you look there — the answer is graded on the
trace's number.

Some tracing tools "fix" this display by shifting child spans to fit inside
their parent, and the Collector can rewrite timestamps too. Both hide the
symptom and leave the host writing wrong times into every log line, token
and certificate check it touches.

## Your objectives

1. In `/obs/answers/clock-skew.txt`: the cause, the host, and the offset you
   measured from a trace, in milliseconds.
2. Fix the host's clock so its offset is under 1 ms, and leave the other
   hosts' clocks right.

## What you're being graded on

- `cause` names the clock; `host` is the skewed host; `offset_ms` is within
  150 ms of the real offset (either sign)
- every host's clock offset is under 1 ms
- in a fresh trace through all three services, each cross-host child span
  starts and ends inside its parent

<details>
<summary>Hint 1 — measuring</summary>

In one trace, take ledger's `POST /entries` server span and its parent,
checkout's `POST /entries` client span. The difference between their start
times is the offset plus a millisecond or so of network. Do it on two or
three traces; the number should not move.

</details>

<details>
<summary>Hint 2 — why not fix it in the Collector</summary>

A `transform` processor could add seconds to ledger's spans. It would have
to know the offset, which drifts on a real host, and every other signal
ledger emits would still be off. The check reads the host's clock.

</details>

<details>
<summary>Solution</summary>

ledger's server span starts a few seconds before checkout's client span in
every trace, the same amount each time, while fulfil's nests. ledger's host
clock is behind by that much:

```
cause: ledger's host clock is behind (clock skew)
host: ledger
offset_ms: -3217     # your number: ledger span start minus checkout client span start
```

Step the clock:

```
echo 0 > /obs/hosts/ledger/clock-offset
```

New traces nest. Old ones stay wrong: their timestamps were written by a
wrong clock and nothing can tell how wrong after the fact. On a real host,
also find out why time sync stopped — a blocked UDP 123, a disabled
`chronyd`, a VM restored from a snapshot — or it drifts again.

### The ways this goes wrong

- **Debugging propagation.** Parent and trace ids are right; only the times
  are off, and only on one host.
- **Shifting ledger's spans in the Collector or the SDK.** The traces look
  fine and the host clock is still wrong; the check reads the clock.
- **Setting the other hosts to match ledger.** Spans nest, and now every
  host is wrong.
- **Getting close.** An offset of 50 ms still puts ledger's span outside a
  parent that lasts a few milliseconds; the bound is 1 ms.

</details>
