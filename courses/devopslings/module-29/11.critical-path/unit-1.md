---
title: "The longest span is not why checkout is slow"
---

## The situation

`POST /checkout` builds the order summary page: it checks the session, loads
and prices the cart, asks six warehouses for stock, and fetches
recommendations from the model team's service. It takes about half a second,
and the product team wants it faster.

The first proposal in the channel: "the trace's biggest bar is
recommendations, 300 ms — get the model team to speed it up." Look before
agreeing:

```
curl -s -X POST http://checkout:8080/checkout
curl -s 'http://tempo:3200/api/search?q={name="POST /checkout"}&limit=3' | jq -r '.traces[].traceID'
```

Open one of them in Grafana (`http://localhost:13000`, Explore, Tempo) and
look at the waterfall, or print the spans with their offsets from the start:

```
curl -s http://tempo:3200/api/traces/<trace id> | jq -r '
  [.batches[].scopeSpans[].spans[]] as $s | ($s | map(.startTimeUnixNano | tonumber) | min) as $t0
  | $s | sort_by(.startTimeUnixNano)[]
  | "\((.startTimeUnixNano | tonumber) - $t0 | ./1e6 | floor)ms +\((.endTimeUnixNano | tonumber) - (.startTimeUnixNano | tonumber) | ./1e6 | floor)ms  \(.name)"'
```

The source is `/obs/apps/checkout.py`. `ledger.py` is the warehouse stock
service, which the inventory team runs; leave it alone. Saving a file
restarts that service; output is in `/obs/logs/<name>.log`.

## The critical path

A request's latency is set by the longest chain of work that has to happen
one step after another, from the first span to the last. That chain is the
**critical path**. A span off it can get faster, or slower up to a point,
without the request noticing, because something else is still running.

So the question to ask of a waterfall is not "which bar is longest" but
"at each moment, what is the request waiting for?" Where two branches run at
the same time, the request waits for the longer one. Walk the trace from the
end backwards: the root ends when its last child ends; that child started
when the thing before it finished; keep following whatever finished last.

That also tells you what a fix saves. Shorten the critical path, and the
request gets faster only until another branch becomes the longest — then
that branch is the new critical path, and every millisecond past that point
is a millisecond the request does not see. A prediction that ignores the
other branches is wrong by exactly that amount.

Jaeger and Grafana's trace view can highlight the critical path for you;
doing it by hand once is how you know what the highlight means.

## Your objectives

1. In `/obs/answers/critical-path.txt`, name the spans that make up the
   critical path, and predict how many milliseconds `POST /checkout` saves
   once they run side by side instead of one after another. Predict before
   you change the code.
2. Make that change in `checkout.py`. `in_background` already runs a
   function on a thread inside the current trace context; recommendations
   uses it.

## What you're being graded on

- `chain` names the spans on the critical path
- in a fresh trace, the six `GET /stock` calls overlap in time, and
  recommendations still takes its 300 ms
- the median of 15 requests, against the median measured when the lesson
  started, has fallen by your `saving_ms` within 40 ms or 20%, whichever is
  larger

<details>
<summary>Hint 1 — what runs beside recommendations</summary>

recommendations starts on a thread and checkout immediately goes on to
something else on its own thread. Add up how long that something takes,
start to finish, and compare it with 300 ms.

</details>

<details>
<summary>Hint 2 — the prediction</summary>

In parallel, six calls take as long as the slowest one. Then the two
branches are that and recommendations. The request waits for the longer of
the two.

</details>

<details>
<summary>Solution</summary>

The critical path is the six `GET /stock` calls: 70 + 95 + 60 + 85 + 100 + 75
= 485 ms, one after another, while recommendations takes 300 ms beside them.
Speeding up recommendations by any amount saves nothing.

Run the stock calls side by side, in `/obs/apps/checkout.py`:

```python
pending = [in_background(stock, w) for w in WAREHOUSES]
available = sum(wait() for wait in pending)
```

The stock branch drops to the slowest warehouse, ~100 ms, and
recommendations becomes the critical path. The request saves 485 − 300 =
**~185 ms**, not 485 − 100 = 385: past 300 ms, it is waiting for
recommendations anyway.

```
chain: GET /stock
saving_ms: 185
```

Now, and only now, a faster recommendations call would make checkout faster
— by up to 200 ms, until the stock branch is the longest again.

### The ways this goes wrong

- **Optimising the longest span.** recommendations is off the critical
  path; the request takes as long as the stock chain either way.
- **Predicting the whole chain** (485) or **the chain minus the slowest
  call** (385). Both forget recommendations, which takes over as the
  longest branch.
- **Parallelising with bare `threading.Thread`.** The calls overlap, and
  their spans start new traces because the thread does not carry the
  context; `in_background` exists for that.
- **Making the warehouses answer faster** in `ledger.py`. That is another
  team's service, and the check rejects it.

</details>
