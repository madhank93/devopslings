---
title: "Looking up one failed request reads every line shop logged"
---

## The situation

Support's tickets look like this: *"request `req-3f9a…` failed, payments
returned a 500."* To find out why, someone runs support's lookup in Loki:

```
{app="shop"} |= "${request_id}"
```

with the request ID filled in. It works, but it is slow, and it gets slower
every week. People have started grepping the hosts instead.

shop's logs reach Loki through Vector, configured by
`/obs/vector/ship.yaml`. Every line is JSON:

```
{"level":"error","service":"payments","request_id":"req-…","method":"GET","path":"/payments/charge","status":500,"duration_ms":412,"customer":"c-0193"}
```

The suggested fix, in the ticket that asked for this work: *"make
`request_id` a label, then the lookup is an index hit."*

## What a query costs in Loki

Loki indexes labels and nothing else. A query does two things:

1. The **stream selector**, `{…}`, picks streams using the index. This part
   is cheap.
2. Every line in those streams, inside the time range, is decompressed and
   checked against the **line filter**, `|= "…"`. This is where the time
   goes.

So a lookup costs the number of lines in the streams its selector picks.
`{app="shop"}` picks all of them.

The way to make it cheap is to make the selector pick fewer lines. A label
on `request_id` does that, and creates a new stream for every request.
Every stream has its own index entries and its own chunks. A chunk holding one
line compresses to nothing, and Loki's own documentation calls this the
mistake that breaks clusters. The same goes for any label with thousands of
values, such as a customer ID or a path with an ID in it.

The labels that help are the ones the person asking already knows, with few
values each. Read the ticket again.

Each query's cost is in its statistics: `logcli query --stats '…'` prints
`Total lines processed`. In Grafana Explore, open **Query inspector** and look
under **Stats**.

## Trying a config

```
shop-logs ship
```

sends a fresh batch of 6000 lines through Vector with your `ship.yaml`, and
prints a payments error you can look up. Vector's labels are templates over
the parsed fields: `service: "{{ service }}"`. Every batch is new, so a label
choice from an earlier batch does not carry over. Loki keeps the old
streams, but they will not match a lookup on a new request.

## Your objectives

1. Change the labels in `/obs/vector/ship.yaml` so that a failed request's
   lookup reads a small slice of the logs.
2. Rewrite `/obs/queries/lookup.logql` to use them. Keep `${request_id}` where
   the request ID goes; the check fills it in.

## What you're being graded on

The check ships its own fresh batch of 6000 lines with your config, then:

- no label has more than 20 different values in the batch, and every line
  arrived
- your lookup, run for real payments errors in the batch, returns exactly
  that one line each time
- the streams your lookup's selector picks hold at most 60 of the batch's
  6000 lines (1%)

<details>
<summary>Hint 1 — what the ticket tells you</summary>

The ticket gives you three facts: the request ID, the service (payments),
and the outcome (an error). One of them has thousands of values. The other
two have a handful each.

</details>

<details>
<summary>Hint 2 — the budget</summary>

payments is about 8% of shop's traffic, and errors are about 2% of
everything. Labelling one of them gets you part of the way. The budget needs
both.

</details>

<details>
<summary>Solution</summary>

```yaml
    labels:
      app: shop
      service: "{{ service }}"
      level: "{{ level }}"
```

```
{app="shop", service="payments", level="error"} |= "${request_id}"
```

Six services and three levels make at most 18 streams. The lookup picks one
of them, about 0.2% of the lines, and the line filter finds the request
inside it. The request ID is still in every line. A filter on it is cheap
once the selector has narrowed the search.

Labelling by `status` instead of `level` works just as well. Both have a
handful of values, and both describe what the ticket says.

### The ways this goes wrong

- **`request_id` as a label.** The lookup becomes an index hit, and the
  batch becomes 6000 streams of one line each. Every week of traffic adds
  millions more. The index outgrows memory, ingestion slows, and in the end
  Loki refuses pushes at its stream limit. For a request-ID lookup, the fix is
  a selector that narrows the search, not an index entry for every request.
- **`customer` or `path` as a label.** These have thousands of values for the
  same reason. `/catalog/item/48213` is a different path for every item.
- **`service` alone.** It is a good label, and the lookup still reads all of
  payments, about 8% of everything. On a busy day that is millions of lines.
- **Dropping the info lines in Vector** to make Loki smaller. The lookup gets
  cheaper, and the next ticket asks about a request that was logged at info.

</details>
