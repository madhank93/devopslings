---
title: "One poison message stops the queue"
---

## The situation

An order queue lives in SQLite inside the `checkout` container. A consumer
takes the oldest pending message, hands it to `orders.handle()` — which ships
the order — and marks it done. When it is empty, the consumer exits.

```
$ ../../scratch/dead-letter-queue/run.sh
queue seeded: 30 orders
message 1 done
...
message 5 failed: StockBusy('stock service busy for order 5, try again'); retrying
message 5 done
...
queue drained
---
pending     0
shipped     30 of 30 orders
dead_letter 0
```

Every fifth order fails once, because the stock service is briefly busy, and
succeeds on the retry. The consumer retries everything that fails. That is
why it works.

At verify time the queue is refilled with one difference: order 4 arrives
malformed — a producer sent `"qty": "two"`. It will fail every time it is
handled, for ever.

## Why retrying everything is a trap

Retrying is right for a failure that might go away. It is wrong for one that
cannot, and a consumer that retries without a limit cannot tell them apart. It
retries the bad message, and because it processes in order, the 26 good
orders behind it wait. Nobody's order ships, and the consumer looks healthy:
it is running, it is busy, it is logging.

That is a *poison message*, and the defence is a *dead-letter queue*: a place
where a message goes after it has failed too many times, so the queue can move
on and a human can look at it.

## Your objectives

1. Every good order ships, including the ones that fail once.
2. Order 4 ends up in `dead_letter` with its original body — not deleted, not
   marked done, not left to retry.
3. The consumer drains the queue and exits within 30 seconds.

## What you're being graded on

The check refills the queue with order 4 malformed, runs your `consumer.py` for
at most 30 seconds, and reads the queue:

- no message still `pending`;
- all 29 good orders in `shipped`;
- message 4 in `dead_letter`, body intact;
- no good order in `dead_letter`.

Deleting order 4 by hand before you verify does nothing: it arrives at verify
time.

## Where things are

Your files are in `scratch/dead-letter-queue/` at the repository root:

| File | What it is |
|---|---|
| `consumer.py` | the consumer. This is the file you change. |
| `orders.py` | the schema and the handler. It is the lesson's — the check uses its own copy, so edits here are not graded. Read it for the tables: `messages` has `attempts` and `last_error` columns, and `dead_letter` exists, empty. |
| `run.sh` | deploys both files, refills the queue, and runs the consumer for up to 30s. `run.sh --poison` refills it as the check does. |

<details>
<summary>Hint 1 — what the consumer forgets</summary>

Look at what the consumer knows about a message when it picks it up for the
tenth time. Nothing — it does not know it has seen it before. The `attempts`
column is there and nothing writes to it.

A retry policy needs a memory, and the memory has to survive the consumer
restarting, so it belongs in the queue, not in a Python variable.

</details>

<details>
<summary>Hint 2 — how many attempts</summary>

Parking a message after its first failure makes the queue drain quickly, and
sends the busy-stock orders to `dead_letter` with the poison one. They would
have succeeded on the next try. A dead-letter queue full of messages that were
fine trains the people reading it to ignore it.

The limit needs to be high enough to ride out the failures that clear and low
enough that one that does not clear costs seconds, not forever. A short,
growing pause between attempts makes a small number go further.

</details>

<details>
<summary>Hint 3 — parking is a move, not a delete</summary>

When the limit is reached, the message has to *leave* `messages` — so the
consumer stops picking it — and *arrive* in `dead_letter`, with its body and
the error that put it there. Do both in one transaction: a crash between them
either loses the message or parks it twice.

</details>

<details>
<summary>Solution</summary>

Count attempts in the queue, back off between them, and after five failures
move the message:

```python
MAX_ATTEMPTS = 5

    except Exception as exc:
        attempts += 1
        error = repr(exc)
        with conn:
            if attempts >= MAX_ATTEMPTS:
                conn.execute(
                    "INSERT INTO dead_letter (message_id, body, error, attempts)"
                    " VALUES (?, ?, ?, ?)", (msg_id, body, error, attempts))
                conn.execute(
                    "UPDATE messages SET status = 'dead', attempts = ?, last_error = ?"
                    " WHERE id = ?", (attempts, error, msg_id))
            else:
                conn.execute(
                    "UPDATE messages SET attempts = ?, last_error = ? WHERE id = ?",
                    (attempts, error, msg_id))
        if attempts < MAX_ATTEMPTS:
            time.sleep(0.1 * 2 ** attempts)
        continue
```

The full file is in the lesson's `solution/` directory.

Before:

```
not yet: the queue is stuck behind message 4.
  After 30s, 3 of 29 good orders had shipped and message 4 was
  still pending (0 attempts recorded).
```

After:

```
shipped 29 of 29 good orders; pending 0; dead_letter 1
PASS — message 4 parked (ValueError("invalid literal for int() with base 10: 'two'")), all 29 good orders shipped.
```

### Retryable and not

The bounded retry treats every error alike, and spends four attempts on a
message that was hopeless from the first. You can do better by classifying:
a `ValueError` from parsing the body will never go away, so park it
immediately; a `StockBusy` or a timeout might, so retry it. Most brokers
cannot see your exception types, which is why they offer only the count — but
your consumer can, and both approaches pass the check.

### What happens to a parked message

A dead-letter queue nobody reads is a slower way to drop messages. It needs:

- **an alert** on its depth, so a human finds out the same day;
- **the error and the body**, so they can tell a producer bug from a consumer
  bug without reproducing it;
- **a replay path**, so once the cause is fixed the message goes back into
  the queue rather than being re-entered by hand.

Brokers build this in: SQS has a redrive policy with `maxReceiveCount`,
RabbitMQ a dead-letter exchange, Kafka consumers conventionally a `.DLT`
topic. The mechanism differs; the three requirements do not.

### What ordering costs

This consumer processes strictly in order, which is what made one message
able to block all of them. If the orders were independent, moving a failed
message to the back of the queue would have kept the rest flowing even
without a limit — and would still have retried order 4 for ever. Bounding
attempts is what actually ends it; reordering only changes who waits.

</details>
