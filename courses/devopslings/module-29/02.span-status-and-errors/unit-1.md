---
title: "ledger returns 500s, and every one of its spans says OK"
---

## The situation

ledger records the payment entry for every order. Some entries fail: a
currency ledger has no account for, or an amount that is not positive. Those
get a 500, and ledger prints the exception to its log.

```
curl -s -XPOST ledger:8080/entries -d '{"order_id":"ord-2","amount":5,"currency":"JPY"}' -w '%{http_code}\n'
tail -n 3 /obs/logs/ledger.log
```

Every request has a span in Tempo, and every span has status `OK`, or
rather unset, which every tool shows as OK. A search for
`{resource.service.name="ledger" && status=error}` finds nothing, and an
error rate built from spans says ledger has never failed. The spans even carry
`http.response.status_code = 500`; nothing reads that as a failure.

The source is `/obs/apps/ledger.py`. Saving it restarts ledger.

## What a span says about failure

A span has a **status** with three values: `Unset`, the default; `Ok`, which
a service sets only to override a later judgement; and `Error`. The status
is what `{status=error}`, Grafana's error panels and span-derived error rates
read.

Separately, a span can carry **events**: timestamped notes. The SDK's
`span.record_exception(e)` adds an event named `exception` with three
attributes from the exception object: `exception.type`,
`exception.message` and `exception.stacktrace`. It does not change the
status. An event says what happened; the status says whether the operation
failed. They are two calls.

`start_as_current_span` does both for you, but only when the exception
leaves the `with` block. ledger catches it inside the block, to turn it into
a 500, so the SDK never sees it. Once you catch an exception, recording it on
the span is your job:

```python
span.record_exception(e)
span.set_status(trace.Status(trace.StatusCode.ERROR, str(e)))
```

`print()` and `logging` go to the log. Nothing written there reaches the span.

## Your objectives

Make each failed entry's span say that it failed, and why: status error, and
an exception event for the exception that failed it. Successful entries stay
as they are, and the responses do not change.

## What you're being graded on

The check sends 24 entries of its own, some of each failing kind, then reads
their spans from Tempo:

- the number of its spans with `status=error` equals the number of 500s it got
- each of those spans has an `exception` event with `exception.type` and
  `exception.message`, for the exception `record()` raised
- ledger still answers 201 and 500 as before

<details>
<summary>Hint 1 — where</summary>

The `except` block in `do_POST` runs inside the `with` block, while `span`
is the current span. That is the one place that knows both the span and the
exception.

</details>

<details>
<summary>Hint 2 — two calls</summary>

If Tempo now shows an `exception` event and `{status=error}` still finds
nothing, you recorded the exception and did not set the status.

</details>

<details>
<summary>Solution</summary>

In `/obs/apps/ledger.py`:

```python
                try:
                    record(entry)
                    code = 201
                except Exception as e:
                    print(f"ledger: entry {entry.get('order_id')} failed: {type(e).__name__}: {e}", flush=True)
                    span.record_exception(e)
                    span.set_status(trace.Status(trace.StatusCode.ERROR, str(e)))
                    code = 500
```

### The ways this goes wrong

- **Logging the error better.** A structured log line with the order ID is
  useful, and the span still says OK.
- **`record_exception` alone.** The event is there, in the trace view, and
  `{status=error}` still finds nothing.
- **`set_status` alone.** Searches find the failure, and the trace cannot
  say whether it was a currency or an amount.
- **Re-raising the exception.** `start_as_current_span` then marks the span,
  and the exception escapes `do_POST`: the client gets a dropped connection
  instead of a 500.
- **Setting the error status after the `with` block, or on every span.** The
  span has already ended, or the 201s turn red too. An error rate that counts
  successes is worse than none.

</details>
