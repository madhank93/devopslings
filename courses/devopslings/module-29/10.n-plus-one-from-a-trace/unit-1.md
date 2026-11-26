---
title: "No query is slow and the order page takes a third of a second"
---

## The situation

checkout serves the order page, `GET /orders/<id>`, from the shop database.
A customer with a big order opened a ticket: their page takes a third of a
second, every time. The order id is printed when the lesson starts and is in
the comment at the top of `/obs/answers/n-plus-one.txt`. Time it:

```
curl -s -o /dev/null -w '%{time_total}s\n' http://checkout:8080/orders/<id>
```

The database team checked their side and every query on these tables
finishes in well under a millisecond. They are right.

The source is `/obs/apps/checkout.py`. Saving it restarts checkout; its
output is in `/obs/logs/checkout.log`.

## Reading a trace for shape, not for the slow span

Module 10's `n-plus-one` found this pattern from the database: one statement
with a call count in the thousands in `pg_stat_statements`. From the trace
side it looks different. Find the request in Tempo:

```
curl -s 'http://tempo:3200/api/search?q={span.order.id="<id>"}&limit=5' | jq -r '.traces[].traceID'
curl -s http://tempo:3200/api/traces/<trace id> \
  | jq -r '[.batches[].scopeSpans[].spans[].name] | group_by(.) | map("\(length)  \(.[0])")[]'
```

or open it in Grafana (`http://localhost:13000`, Explore, Tempo). Sort by
duration and nothing stands out — no span above a couple of milliseconds.
Look at it as a shape instead: a wall of short identical `CLIENT` spans,
one after the other, under one server span. Each is a round trip to the
database, and a round trip costs network time whatever the query: about a
millisecond here, often more between real hosts.

That is the N+1 query: one query for the list, then one more per element.
It scales with the data, so the small orders a developer tests with are
fast and the biggest customer's page is slow. An index makes each query
cheaper; it does nothing about how many there are.

The same signal works as a standing check: count `db.system.name` spans per
trace and alert when a route's count grows with its input.

## Your objectives

1. Fill in `/obs/answers/n-plus-one.txt`: the name of the span that repeats
   in a request for the ticket's order, and how many times it appears in one
   request.
2. Fix `checkout.py` so an order page takes a small, fixed number of
   database round trips whatever the order's size, and the five biggest
   orders' pages answer with p95 under 80 ms. The page still lists every line
   item, from the database.

## What you're being graded on

- the answer names the repeated span exactly as Tempo shows it, and its count
  matches that order's line items
- the check restarts checkout, then requests five orders of different sizes
  with trace ids it chose; in Tempo each request has the same number of database (`CLIENT`)
  spans, between one and three, and every response lists every item
- p95 over 40 requests for the five biggest orders is under 80 ms

<details>
<summary>Hint 1 — counting the spans</summary>

The `jq` above groups the trace's span names with a count each. One name
appears once per line item; the others appear once per request.

</details>

<details>
<summary>Hint 2 — the shape of the fix</summary>

The line items and the products they point at can come back in one
statement: a `JOIN`, or a second query with `WHERE id IN (...)`. Either is
a fixed number of round trips. A cache is not: the first request for each
order still pays every one, and the check reads the trace.

</details>

<details>
<summary>Solution</summary>

The repeated span is `SELECT shop.products`, once per line item. In
`/obs/apps/checkout.py`, fetch the items with their products in one query:

```python
for sku, name, qty, price in query(
        "SELECT p.sku, p.name, i.qty, p.price_cents FROM order_items i JOIN products p"
        " ON p.id = i.product_id WHERE i.order_id = ? ORDER BY i.id", (order_id,)):
    items.append({"sku": sku, "name": name, "qty": qty, "price_cents": price})
```

Two round trips per page now, whatever the order's size.

### The ways this goes wrong

- **An index.** `order_items` is already indexed and `products` is looked up
  by primary key; each query was never the problem.
- **A cache.** Warm requests skip the database, cold ones still make one
  round trip per item, and a page served with no database span is not one
  the check accepts.
- **Running the queries in parallel threads.** The page gets faster up to
  the pool's size, and the database now takes a burst of N queries per page
  view.
- **Counting every database span.** The order lookup and the item list run
  once each; the count asked for is the span that repeats.

</details>
