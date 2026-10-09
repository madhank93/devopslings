---
title: "At-least-once delivery charges twice"
---

## The situation

This lesson adds a third service to the stack: `payments`, which records a
charge in a SQLite ledger for every `POST /charge`. A client charges a batch of
30 orders through toxiproxy, retrying any attempt that gets no answer:

```
$ ../../scratch/idempotency-keys/run.sh
ok 1 1
ok 2 2
...
ok 30 30
---
ledger: 30 charges for 30 orders
```

Thirty orders, thirty charges. Nothing is wrong.

At verify time, one response in four from `payments` will be lost on the way
back — *after* the charge has been written. `payments` stays up and correct
the whole time. What changes is that the client, for a quarter of its
requests, never hears that the charge went through.

## Why the retry is both right and dangerous

From the client's side, a request that gets no answer is ambiguous. It may
never have arrived. It may have arrived, been charged, and had its answer
dropped. The client cannot tell these apart, and the network delivers both.

So the client retries, and it should: not retrying means telling a customer
their payment failed when it did not. That is *at-least-once* delivery — every
payment arrives, and some arrive twice. The second arrival is the one that
charges the customer again.

Retries are only safe when repeating a request has the same effect as sending
it once. A `GET` has that property for free. A charge does not, unless you give
it one.

## Your objectives

1. Every order is charged exactly once while responses are being lost.
2. Every order is reported `ok` to the customer.

Objective 2 is not decoration. A client that stops retrying passes objective 1
and fails objective 2: the customer was charged and told they were not.

## What you're being graded on

The check deploys your two files, empties the ledger, injects the fault, and
charges the same 30-order batch. Then it reads the **ledger** — not the
client's exit status:

- exactly 30 rows in `charges`, matching the 30 orders;
- 30 `ok` lines from the client, whose charge ids are the ledger's ids;
- and, sent straight to `payments` with no fault in the way: the same
  `Idempotency-Key` twice returns the same charge, and a new key with the same
  body is a new charge.

The batch contains every customer-and-amount pair twice, on purpose. Two
coffees are two charges.

## Where things are

Your files are in `scratch/idempotency-keys/` at the repository root:

| File | What it is |
|---|---|
| `payments.py` | the server. Keep the `charges` table and its `id`, `customer`, `amount` columns — the check reads them. Add whatever else you need. |
| `client.py` | the client. Keep its `ok <order> <charge_id>` output — the check reads it. |
| `run.sh` | deploys both files into the stack, empties the ledger, runs the batch. Run it after every edit. |

To see the failure before you are graded on it, put the fault on yourself:

```
curl -s -X POST localhost:8474/proxies/payments/toxics -H 'Content-Type: application/json' \
  -d '{"name":"lost_response","type":"limit_data","stream":"downstream","toxicity":0.25,"attributes":{"bytes":0}}'
../../scratch/idempotency-keys/run.sh
```

and take it off with
`curl -s -X DELETE localhost:8474/proxies/payments/toxics/lost_response`.

<details>
<summary>Hint 1 — the client cannot fix this alone</summary>

The obvious first move is to deduplicate in the client: remember which orders
have been charged and do not send them again. But the client does not *know*
which ones were charged — that is the whole problem. The answer that would
have told it was the thing that got lost.

The only party that knows whether a charge happened is the one that recorded
it. So the server has to be able to recognise a retry, and the client has to
send something that lets it.

</details>

<details>
<summary>Hint 2 — what makes two requests "the same"</summary>

Not their contents. `bob 12.50` twice is either one payment retried or two
purchases, and the bodies are identical in both cases. Deduplicating on
customer and amount refunds the second coffee.

What distinguishes them is *intent*: one attempt to pay, however many times it
is sent. Give that intent a name the client makes once and sends every time.
The conventional header is `Idempotency-Key`, and it is the one the check uses.

</details>

<details>
<summary>Hint 3 — when the key is made matters</summary>

A key made inside the retry loop is a new key on every attempt, and the server
sees every retry as a new payment. The key belongs to the order, so make it
before the first attempt.

On the server, a key it has seen before must get the *original* answer back —
same charge id, success status. A `409 Conflict` is truthful and useless: the
client retried precisely because it never saw the first answer.

</details>

<details>
<summary>Solution</summary>

`client.py` makes one key per order, outside the retry loop, and sends it on
every attempt:

```python
def charge(customer, amount):
    key = str(uuid.uuid4())
    for _ in range(ATTEMPTS):
        try:
            r = requests.post(
                f"{URL}/charge",
                json={"customer": customer, "amount": amount},
                headers={"Idempotency-Key": key},
                timeout=(1, 3),
            )
```

`payments.py` records each key next to the charge it produced, and looks the
key up before charging:

```python
conn.execute("BEGIN IMMEDIATE")
if key:
    seen = conn.execute(
        "SELECT c.* FROM idempotency_keys k JOIN charges c ON c.id = k.charge_id"
        " WHERE k.key = ?", (key,)).fetchone()
    if seen:
        conn.execute("COMMIT")
        return answer(seen)
cur = conn.execute("INSERT INTO charges (customer, amount) VALUES (?, ?)", ...)
if key:
    conn.execute("INSERT INTO idempotency_keys (key, charge_id) VALUES (?, ?)",
                 (key, cur.lastrowid))
conn.execute("COMMIT")
```

with `key TEXT PRIMARY KEY` on the new table. The full files are in the
lesson's `solution/` directory.

Before:

```
batch: 30 of 30 orders answered ok, 0 FAILED; ledger: 40 charges
not yet: 30 orders, 40 charges — 10 payments were charged twice.
```

After:

```
batch: 30 of 30 orders answered ok, 0 FAILED; ledger: 30 charges
PASS — 30 orders, 30 charges, every customer told the truth,
```

### Why the lookup and the insert are one transaction

Two copies of the same request can arrive at the same moment — a client that
times out at 3s and retries while the first attempt is still being processed.
If both look up the key, both find nothing, and both insert, you have the
double charge back. `BEGIN IMMEDIATE` takes SQLite's write lock before the
lookup, so the second waits for the first and then finds its key. In Postgres
you would get the same guarantee from a unique constraint on the key and
`INSERT ... ON CONFLICT`. Whatever the database, the check-then-act has to be
atomic.

### What a real implementation adds

- **Scope and expiry.** Keys are stored per account and kept for a bounded
  window — Stripe keeps them 24 hours. The window has to outlast the client's
  longest retry, and no longer.
- **Matching bodies.** A reused key with a *different* body is a client bug,
  not a retry. Store a hash of the request and reject a mismatch with `422`.
- **In-flight requests.** A replay that arrives while the original is still
  running should wait or get `409` with `Retry-After`, never run it twice.

### The general shape

At-least-once delivery plus an idempotent receiver is how almost every
"exactly-once" system actually works — message queues, webhooks, payment
APIs. Exactly-once *delivery* is not on offer from a network. Exactly-once
*effect* is, and it is the receiver's job, using an identity the sender
provides.

</details>
