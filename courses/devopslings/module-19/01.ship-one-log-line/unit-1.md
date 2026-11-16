---
title: "One payment failed, and the log line that says why is not in Loki"
---

## The situation

Twenty minutes ago a customer's card was declined. Support wants to know why.
payments wrote the reason to `/obs/logs/payments.log`, one JSON object per
line:

```
{"ts":"…","level":"error","service":"payments","order_id":"ord-…","customer":"c-…","msg":"payment declined: card expired"}
```

The team has just stood up Loki, and nothing ships to it yet. Before wiring up
a pipeline, ship this one line by hand and find it again. That is enough to
learn the one decision every log pipeline makes: which parts of a record become
**labels**, and which stay in the **line**.

The order ID was printed when the lesson started, and is in
`/obs/run/declined-order`.

## How Loki stores a line

Loki groups lines into **streams**. A stream is one exact set of labels, such
as `{service="payments", level="error"}`. Loki indexes only the labels. The
line itself is compressed into chunks and never indexed.

A query works the same way round. It picks streams by their labels, then reads
every line in them, filtering as it goes:

```
{service="payments", level="error"} |= "ord-12345"
```

So a label is something you pick streams by, with few possible values: the
service, the level, the environment. Something that is different on every
event, such as an order ID, a customer or a timestamp, belongs in the line. As
a label it would create a new stream for every order. Loki would index, store
and list each of those streams separately, and keep doing so.

## Pushing a line

Loki accepts lines over HTTP:

```
curl -H 'Content-Type: application/json' http://loki:3100/loki/api/v1/push -d '{
  "streams": [
    { "stream": { "label": "value" },
      "values": [ [ "<unix epoch in nanoseconds, as a string>", "<the line>" ] ] }
  ]}'
```

The timestamp is the time the event happened, not the time you push it.

To read it back, use `logcli query '<LogQL>' --since=1h` or the
`/loki/api/v1/query_range` endpoint. In Grafana, the **Loki** datasource is
under Explore.

## Your objectives

1. Push the decline line into Loki unchanged, in the stream
   `{service="payments", level="error"}`, at the time payments logged it.
2. Write a LogQL query that finds it to `/obs/queries/declined.logql`.
3. In `/obs/answers/ship-one-log-line.txt`, say which of the record's fields
   ended up as labels and which stayed in the line:

   ```
   labels: <fields>
   line: <fields>
   ```

## What you're being graded on

- your query returns exactly one entry for the declined order, and it is the
  line payments wrote, byte for byte
- that entry's stream has `service` and `level` labels, and no label holds
  anything unique to the event
- the entry's timestamp is the record's `ts`
- the answer's labels are the labels the stream really has, and `order_id` is
  in the line

Loki has no undo for a push. If you push with the wrong labels, restart the
lesson. You get a new order ID, so the old entries never match.

<details>
<summary>Hint 1 — the timestamp</summary>

GNU `date` reads ISO 8601: `date -d 2026-01-01T10:00:00.123Z +%s%3N` prints
milliseconds since the epoch. Append six zeros for nanoseconds.

</details>

<details>
<summary>Hint 2 — the line inside JSON</summary>

The line is JSON, and it goes inside a JSON string. `jq -n --arg line "$line"`
does the quoting for you.

</details>

<details>
<summary>Solution</summary>

```bash
oid=$(cat /obs/run/declined-order)
line=$(grep -F "\"$oid\"" /obs/logs/payments.log)
ns=$(date -d "$(jq -r .ts <<<"$line")" +%s%3N)000000

jq -n --arg ts "$ns" --arg line "$line" \
  '{streams: [{stream: {service: "payments", level: "error"}, values: [[$ts, $line]]}]}' |
  curl -H 'Content-Type: application/json' --data-binary @- http://loki:3100/loki/api/v1/push

echo "{service=\"payments\", level=\"error\"} |= \"$oid\"" > /obs/queries/declined.logql
logcli query "$(cat /obs/queries/declined.logql)" --since=1h
```

```
labels: service, level
line: ts, order_id, customer, msg
```

`service` and `level` became labels. They are the questions you ask before
you know which line you want: "errors from payments". Everything else stays
in the line, because each value names one event. `|= "ord-…"` finds it inside
the one stream the selector picked, without Loki indexing it. It also stays in
the line, so whoever reads the result sees the whole record.

### The ways this goes wrong

- **`order_id` as a label.** It works for one order. Across a day it creates
  a stream per order, the index grows with traffic, and Loki starts refusing
  pushes once it hits its stream limit. This is the subject of a later lesson.
- **Pushing only the message.** The line no longer says which order, which
  customer or when it happened. The labels cannot hold that information, so
  it is gone.
- **Pushing with `date +%s%N`.** The line is stored twenty minutes after the
  event. A query for the time of the decline misses it, and a query for "the
  last five minutes" shows it as new.

</details>
