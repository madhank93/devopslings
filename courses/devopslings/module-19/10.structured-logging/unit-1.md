---
title: "Which errors did order 812 hit? Only a regex knows"
---

## The situation

dispatch picks paid orders in the warehouse and hands them to couriers. It
logs with Python's `logging` module, and every line goes to Loki in the stream
`{service="dispatch"}`:

```
2026-11-23 10:14:02,118 INFO order 812 picked in ams-2, 3 items
2026-11-23 10:14:02,119 ERROR order 812 rejected by courier ups in ams-2: no pickup slot left
2026-11-23 10:14:02,403 INFO restocked shelf B-812 with 40 units of sku 1812
```

Support asks which errors order 812 hit today. The only way to answer is a
regex over the text:

```
{service="dispatch"} |~ "ERROR.*812"
```

That also matches order 8120, shelf B-812 and sku 1812. Tighten it to
`order 812 ` and it breaks the day someone rewords the message. The line has
the facts in it, and nothing says which part is which.

dispatch's source is `/obs/apps/lab.py`. It runs in the `lab` container;
saving the file restarts it, and its own errors are in `/obs/logs/lab.log`.

## Records, not sentences

A **structured** log record is a set of named fields. JSON, one object per
line, is the common shape:

```json
{"ts": "…", "level": "error", "msg": "courier rejected order", "order_id": 812, "warehouse": "ams-2", "courier": "ups"}
```

LogQL's `json` parser turns each field into a label for the rest of the query,
so the question becomes a filter on a field:

```
{service="dispatch"} | json | order_id="812" | level="error"
```

`order_id="812"` is an exact match on one field. It cannot match 8120, and it
does not care how the message is worded.

That only works if the keys are **stable**: the same name, in every record,
for the same thing. `level` in one record and `severity` in the next splits
every query in two. So does an order that is `order_id` in one call and
`orderId` in another.

`msg` names the *event*, with the same text for every order: "courier
rejected order". The values that change go in their own fields. Then
`sum by (msg) (count_over_time(... | json [5m]))` counts events by kind. With
the order number spliced into `msg`, every order is a kind of its own.

Python's `logging` takes per-call fields through `extra=`. They end up as
attributes on the `LogRecord`, where a formatter can read them:

```python
log.info("order picked", extra={"order_id": order, "warehouse": warehouse})
```

The formatter is what turns a record into a line. `logging.Formatter` writes
text; a JSON formatter is a subclass whose `format()` returns `json.dumps(...)`
of the fields you want.

## Your objectives

1. Make dispatch log one JSON object per line, every line, the restock lines
   included. Each record has `level` and `msg`. Each record about an order
   has `order_id` and one more field that every order record carries.
2. Name that field in `/obs/answers/structured-logging.txt`:

   ```
   key: <field name>
   ```

## What you're being graded on

The check reads what dispatch sent to Loki since it last restarted:

- every line is a JSON object with `level` and `msg`
- every record about order 812 has an `order_id` field holding 812, and the
  number is not in `msg`
- every order record carries the field your answer names
- `{service="dispatch"} | json | order_id="812"` returns exactly the records
  about order 812, and some of them have an error level

<details>
<summary>Hint 1 — where the fields go</summary>

`extra={"order_id": order}` puts `order_id` on the record as an attribute.
A formatter sees the record, so it can read it. Collecting the extras under
one attribute, such as `extra={"fields": {...}}`, saves the formatter from
telling your fields apart from the dozen attributes every record has.

</details>

<details>
<summary>Hint 2 — the level</summary>

`record.levelname` is `INFO` or `ERROR`. Lower-case it or not, but keep it:
"errors for order 812" filters on it.

</details>

<details>
<summary>Solution</summary>

A formatter that writes `level`, `msg` and the call's fields:

```python
class JsonFormatter(logging.Formatter):
    def format(self, record):
        rec = {"ts": self.formatTime(record), "level": record.levelname.lower(),
               "msg": record.getMessage()}
        rec.update(getattr(record, "fields", {}))
        return json.dumps(rec)

handler.setFormatter(JsonFormatter())
```

And every call names its event and passes the rest as fields:

```python
log.info("order picked", extra={"fields": {"order_id": order, "warehouse": warehouse, "items": items}})
log.error("courier rejected order", extra={"fields": {
    "order_id": order, "warehouse": warehouse, "courier": courier, "reason": random.choice(REASONS)}})
log.info("order handed to courier", extra={"fields": {"order_id": order, "warehouse": warehouse, "courier": courier}})
log.info("shelf restocked", extra={"fields": {"shelf": shelf, "units": units, "sku": sku}})
```

```
key: warehouse
```

Then:

```
logcli query '{service="dispatch"} | json | order_id="812" | level="error"' --since=5m
```

### The ways this goes wrong

- **A JSON formatter around the old messages.** `{"level": "error", "msg":
  "order 812 rejected by courier ups"}` is JSON and no more searchable than
  before: the order is still inside a sentence.
- **Leaving the restock lines as text.** `| json` fails on them, and every
  query that parses the stream carries an `__error__` for each one.
- **`orderId` in one call, `order_id` in another.** Each name finds half the
  records. Stable keys are a contract between every call site and every
  query.
- **`"msg": f"order {order} picked"` next to an `order_id` field.** The filter
  works, and counting by `msg` now counts orders instead of events.

</details>
