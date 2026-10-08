---
title: "Set a timeout, and know what it bounds"
---

## The situation

`checkout` calls `pricing` on every request, and both are healthy:

```
$ curl -s localhost:18090/checkout
{"elapsed_ms":4,"price":42.0,"source":"pricing","status":"ok"}
```

`checkout` makes that call with no timeout. In Python's `requests`, as in most
HTTP clients, that does not mean "a sensible default" — it means wait forever.

At verify time, `pricing`'s responses will be delayed by ten seconds. Your job
is the smallest change there is: make `checkout` give up within **3 seconds,
worst case**. Not on average, not under this particular fault — worst case.

A `503` is an acceptable answer here. Keeping customers served while `pricing`
is slow is a separate problem, and it is the next lesson's.

## Your objectives

1. Set `checkout`'s timeouts so no call to `pricing` can take longer than 3s.
2. Write `scratch/set-a-timeout/answer.txt` (from the repository root) with
   two lines:

   ```
   fired: <connect or read>
   worst_case: <seconds>
   ```

   `fired` is which of the two timeouts the injected fault makes give up.
   `worst_case` is the longest `checkout` can now wait on `pricing`, given what
   you configured.

## How to configure it

`checkout` reads two timeouts from `sandboxes/chaos-stack/.env`:

```
PRICING_CONNECT_TIMEOUT=   # seconds to wait for the TCP connection to open
PRICING_READ_TIMEOUT=      # seconds to wait for the response once connected
```

`0` means "not set". Compose reads `.env` when it *creates* a container, so
apply an edit with:

```
docker compose -p devopslings-chaos-stack up -d
```

You can put the fault in yourself to watch it, and take it out again:

```
curl -s -X POST localhost:8474/proxies/pricing/toxics -H 'Content-Type: application/json' \
  -d '{"name":"latency","type":"latency","stream":"downstream","attributes":{"latency":10000}}'
curl -s -w '  %{time_total}s\n' localhost:18090/checkout
curl -s -X DELETE localhost:8474/proxies/pricing/toxics/latency
```

## What you're being graded on

- A short k6 run under the 10s fault, with the threshold `max < 3000ms`: every
  request comes back inside the budget, whether as a price or a `503`.
- The timeouts you configured add up to no more than 3s. This is checked
  separately, because the fault only exercises one of them.
- With the fault removed, `checkout` still gets real prices.
- Your answer file.

<details>
<summary>Hint 1 — two waits, not one</summary>

An HTTP call waits twice. First for the TCP connection to be accepted
(**connect**), then, on that open connection, for the response to arrive
(**read**). `requests` takes them as a pair, `timeout=(connect, read)`, and so
does `checkout`.

A dependency can fail at either. A host that silently drops packets hangs the
connect. A host that accepts the connection and then takes ten seconds to
answer hangs the read. Run the fault by hand and look at the `error` field in
`checkout`'s `503` — it names the one that gave up.

</details>

<details>
<summary>Hint 2 — the case you are not shown</summary>

Set only the read timeout to 2 seconds and the k6 run passes: every request
under this fault gives up at 2s. The check still fails, because you have only
bounded the wait the fault happened to exercise.

Look at `_timeout()` in `sandboxes/chaos-stack/app/checkout.py`. When one of the
two values is left at 0, what does `checkout` use for it? Now picture a
request whose connect stalls, and add up how long it can wait.

</details>

<details>
<summary>Solution</summary>

`sandboxes/chaos-stack/.env`:

```
PRICING_CONNECT_TIMEOUT=1
PRICING_READ_TIMEOUT=2
PRICING_FALLBACK=
```

```
docker compose -p devopslings-chaos-stack up -d
```

`scratch/set-a-timeout/answer.txt`:

```
fired: read
worst_case: 3
```

Under the fault:

```
$ curl -s -w '  %{time_total}s\n' localhost:18090/checkout
{"elapsed_ms":2004,"error":"ReadTimeout","status":"error"}  2.01s
```

### Why read

`toxiproxy` sits between the two services. It accepts `checkout`'s connection
immediately and then holds back `pricing`'s response, so the connect completes
in a millisecond and the read is what waits. `ReadTimeout` in the error says so.

### Why the worst case is the sum

The two timeouts are consecutive, not overlapping. A call can spend up to the
full connect timeout getting a connection and then up to the full read timeout
waiting for the answer, so the bound you have actually promised is connect +
read: 1 + 2 = 3 seconds.

That is why setting only one of them is not enough. With `READ=2` alone,
`checkout` fills in connect as 3s and the true worst case is 5s — invisible
under this fault, and exactly what you would see the day `pricing`'s host
starts dropping packets instead of answering slowly.

### One more caveat worth knowing

`requests`' read timeout is the longest gap *between bytes*, not a deadline on
the whole response. A server that trickles one byte every second never trips
a 2-second read timeout. When you need a hard ceiling on total time, it has to
come from somewhere that measures wall-clock — a deadline around the call, or
a proxy in front of it. For a small JSON answer delivered at once, as here,
connect + read is the bound.

### What this does not fix

`checkout` now fails in two seconds instead of hanging. It still fails — every
customer gets a `503`. The next lesson keeps them served.

</details>
