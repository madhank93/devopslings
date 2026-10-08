---
title: "the regex that was right until someone wrote a sentence"
---

## The situation

`slow-services` reports which services had a request slower than 500 ms:

```bash
sed -n 's/.*"service": *"\([^"]*\)".*duration_ms[^0-9]*\([0-9][0-9]*\).*/\2 \1/p' \
    /srv/events/events.jsonl \
  | awk '$1 > 500 {print $2}' \
  | sort -u
```

It was correct when every record was flat, short and machine-generated. Then a
developer wrote an error message containing the words `"duration_ms": 9999`, and
another team started emitting a nested `upstream` object, and someone named a
service `order api`.

Nobody noticed, because the output still looks like a list of service names.

## Your objective

Fix it. The rules, precisely:

- a record counts if **its own** `duration_ms` is **strictly greater than 500**
- a `duration_ms` inside a nested object is not the request's duration
- text inside `"message"` is text, never a field
- print each qualifying service name once, sorted

## What you're being graded on

Your script's stdout, compared against the answer computed from the log's
structure. The check names the specific record you got wrong.

<details>
<summary>Hint 1 — find out what it is actually doing</summary>

```
$ slow-services
auth
cart
checkout
inventory
order
```

Now read the log and check each one by hand:

```
$ jq -c '{service, duration_ms}' /srv/events/events.jsonl
```

`cart` has a duration of 40. `inventory` has 120. Both are in the output.
`billing` is over 500 and missing. And there is no service called `order`.

Four wrong answers, in both directions, from one line of `sed`.

</details>

<details>
<summary>Hint 2 — why each one is wrong, and why widening does not help</summary>

| record | what happened |
|---|---|
| `cart` | the greedy `.*` before `duration_ms` found the last one on the line — inside its message, `\"duration_ms\": 9999` |
| `inventory` | same greed, different victim: the last `duration_ms` is the nested `upstream` one, `4200` |
| `order api` | extracted correctly as `1503 order api`, then `awk` split it on the space and printed `order` |
| `billing` | its fields are in a different order, and the pattern needs `service` before `duration_ms` |

Now try to fix it with a better regex. Require the quote in `"duration_ms":` and
`cart` goes away, because inside a JSON string that quote is escaped — but
`inventory`'s nested field is still unescaped and still after `service`. Take
the first `duration_ms` instead of the last, and `billing` is still missing.
Allow either field order, and you need two patterns that must not both match.
Print everything after the first field instead of `$2`, and you have encoded
"the name is the rest of the line".

Each patch fixes one case and adds an assumption. That is the signature of
parsing the wrong thing: the rules keep growing and never converge, because
you are pattern-matching a serialisation instead of reading a structure.

</details>

<details>
<summary>Hint 3 — the log is JSON, so use a JSON reader</summary>

```
$ jq -r 'select(.duration_ms > 500) | .service' /srv/events/events.jsonl | sort -u
```

Every problem above disappears at once, and not by coincidence:

- `.duration_ms` is **that record's** field. The nested one is `.upstream.duration_ms`, a different path.
- `> 500` is a numeric comparison. `1503` and `500` both behave correctly; no digit-counting.
- `.message` is a string. A parser knows the difference between bytes inside a string and structure.
- Field order is irrelevant — nothing is anchored on position.

`jq -c` is useful while exploring, and `jq -r` gives raw output without JSON
quoting, which is what you want when feeding `sort`.

</details>

<details>
<summary>Solution</summary>

```bash
#!/bin/bash
set -euo pipefail

jq -r 'select(.duration_ms > 500) | .service' /srv/events/events.jsonl \
  | sort -u
```

Two lines of work, and none of the assumptions.

### Why this is a lesson at all

The original was not sloppy. It was written against real data, it was tested
against that data, and it was correct. What changed was not the code but the
inputs — and the code had silently encoded assumptions about them that nobody
wrote down: that `duration_ms` appears once per line, that it comes after
`service`, that a service name is one word, that message text never resembles a
field.

Three things worth keeping:

1. **Match the structure the data has, not the shape it happens to print in.**
   JSON, YAML, XML and CSV all have parsers. `grep` and `sed` see a line of
   bytes and cannot distinguish structure from content — which is the exact
   distinction every one of these bugs turns on.

2. **Regexes on structured data fail silently and asymmetrically.** This one
   produced both false positives and false negatives, and the output still
   looked like a plausible list of service names. Nothing errored. A report
   that is quietly wrong is worse than one that breaks, because it gets used.

3. **When each fix adds an assumption, you are solving the wrong problem.**
   That is the signal to change tools, and it generalises well past logs — the
   same thing happens to anyone parsing HTML with regexes or grepping `ps`
   output for a field.

`grep` on a log is still completely reasonable when you are looking for a
string and you know it is a string. The mistake is using a line matcher to
answer a question about fields — the same mistake `text-at-scale` makes in
module 01, where `grep -c 503` returns 202,127 against a true 8,493.

</details>
