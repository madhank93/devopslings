---
title: "the function that times out on a cold start"
---

## The situation

`/root/quote` deploys `quote`, a Lambda function, to floci, a local copy of
the AWS API. `quote` prices an order from a rate table it gets from
`pricing`, a service that takes 3.5 seconds to answer. Nobody can make
`pricing` faster, and the table it returns never changes.

The first call to every new instance of `quote` fails:

```
$ ./invoke '{"item": "widget", "qty": 2}'
{"errorMessage": "... Task timed out after 3.00 seconds", "errorType": "TimedOut"}
4.12s  (HTTP 200)
```

The handler fetches the table the first time it runs and keeps it for later
calls, so only the first call pays for it. But that first call pays inside
the handler, and the 3.5-second fetch does not fit in a 3-second timeout.

The first guess is to raise the timeout to 30 seconds. The error goes away.
So does the alarm for the day `pricing` hangs: every stuck call now holds an
instance, and its caller, for half a minute before anyone hears about it.

## Your objectives

1. Measure a cold start (the first call to a new instance) and a warm call
   (a call to an instance that is already running). Write both to
   `/root/quote/LATENCY` in milliseconds, as `cold_ms=` and `warm_ms=` lines.
2. Move the rate fetch out of the request path. It must still come from
   `pricing`, once per instance.
3. Set the timeout from your numbers: enough for a request, with headroom,
   and not a blanket number.
4. Deploy with `tofu apply`, so a plan afterwards is clean.

## What you're being graded on

`tofu plan` must be clean and `quote` must price an order correctly.

Then the grader deploys a copy of your function with a 3-second timeout and
calls it. The first call must succeed and must fetch from `pricing`. Three
warm calls after it must not fetch again. Your `cold_ms` must be within a
factor of two of the cold start the grader measures, and your `warm_ms` must
be a warm number. Last, your timeout must be at least 3 seconds and at least
twice a warm call, and no more than three times a cold start.

<details>
<summary>Hint 1 — making a cold start on purpose</summary>

An instance stays warm for a while after a call. Any change to the function,
whether new code or new configuration, retires the running instances, so the
next call starts a new one. A `tofu apply` that changes something is the
easiest way. Time that call with `./invoke`, then call it a few more times in
a row and take the warm number from those.

</details>

<details>
<summary>Hint 2 — where code runs before the handler</summary>

When an instance starts, the runtime imports your module. Everything at
module scope runs then, in the init phase, once per instance. Only after that
is the handler called, and the timeout counts only from there. Anything the
function needs for every request and that does not change between them
belongs at module scope.

The init phase has a limit of its own. On AWS it is 10 seconds. floci gives
it the function's timeout plus 2 seconds, which is why a timeout under 3
seconds still fails here.

</details>

<details>
<summary>Hint 3 — what the timeout is for</summary>

A timeout is the point at which you decide a call is stuck rather than slow.
With the fetch out of the handler, a request takes milliseconds. A few
seconds is already many times that. Thirty seconds is not headroom, it is a
promise to wait half a minute before saying anything is wrong.

</details>

<details>
<summary>Solution</summary>

`src/handler.py`, with the fetch at module scope:

```python
RATES = fetch_rates()


def handler(event, context):
    item = event["item"]
    qty = int(event.get("qty", 1))
    return {"item": item, "qty": qty, "total": round(RATES[item] * qty, 2)}
```

Deploy it. The new code retires every instance, so the next call is cold:

```
$ tofu apply
  # aws_lambda_function.quote will be updated in-place
$ ./invoke
{"item": "widget", "qty": 2, "total": 9.0}
4.81s  (HTTP 200)
$ ./invoke
{"item": "widget", "qty": 2, "total": 9.0}
0.03s  (HTTP 200)
```

`LATENCY`:

```
cold_ms=4810
warm_ms=30
```

The timeout stays at 3 seconds: a hundred times a warm call, and the cold
start's fetch no longer counts against it. Anything from 3 up to around 10
seconds is defensible with these numbers. 30 is not.

### Where the cold start went

It did not go away. The first caller still waits about five seconds; the
fetch just happens where the timeout does not see it. If that wait matters,
the fixes are elsewhere: provisioned concurrency keeps instances started
ahead of traffic, and a cache or a bundled copy of the table removes the
fetch. Each costs money or freshness. Measuring first tells you whether you
need either.

</details>
