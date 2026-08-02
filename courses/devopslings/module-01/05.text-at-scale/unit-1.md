---
title: "three numbers out of 390,000 lines, before standup"
---

## The situation

Support escalated an incident from yesterday. There is no dashboard for this
service, no log aggregation, and nobody wants to hear "I'd need to ship it to
OpenSearch first". What there is: one access log on one box, and a manager who
wants three specific answers in twenty minutes.

```
$ wc -l /srv/logs/access.log
389567 /srv/logs/access.log

$ head -1 /srv/logs/access.log
198.51.100.118 - cust-00038 [02/Aug/2026:00:00:00 +0000] "PUT /api/v1/orders?page=2 HTTP/1.1" 204 15022 1.805 "curl/8.5.0"
```

## Your objectives

Answer each question by writing the answer, and **nothing else**, into a file.
The questions are also in `/root/questions.txt` on the box.

| file | question | format |
|---|---|---|
| `/root/answers/q1` | how many requests got a 5xx status? | a plain integer |
| `/root/answers/q2` | which customer generated the most 5xx responses? | `cust-00007` |
| `/root/answers/q3` | which single minute of the day served the most requests, counting every status? | `HH:MM` |

Do not modify `/srv/logs/access.log`. The check fingerprints it, and a
modified log means the questions no longer have the answers they were asked
about.

## What you're being graded on

The answers. Not the pipeline, not its runtime, not how many processes it
spawned. A `sort | uniq -c` that takes eleven seconds and is right beats an
elegant one-liner that is wrong — and one of the obvious one-liners here *is*
wrong.

<details>
<summary>Hint 1 — `grep -c 503` is not the answer to question 1</summary>

Try it, then look at what it matched:

```
$ grep -c 503 /srv/logs/access.log
$ grep 503 /srv/logs/access.log | head -3
```

`503` appears in this log as a status, as a byte count, inside a URL path, and
inside a query string. `grep` has no idea which of those you meant, because
you did not tell it. That is the whole problem with searching a structured
line as if it were prose.

The status lives in a *field*. Count fields, not substrings.

</details>

<details>
<summary>Hint 2 — which field is the status?</summary>

`awk` splits on runs of whitespace, so count the fields in one line:

```
198.51.100.118 - cust-00038 [02/Aug/2026:00:00:00 +0000] "PUT /api/v1/orders HTTP/1.1" 204 15022 1.805 "curl/8.5.0"
$1             $2 $3        $4                  $5       $6   $7             $8        $9  $10   $11   $12...
```

The quoted request is three separate fields to awk — it does not know about
quotes. So the status is `$9`, the size `$10`, the customer `$3`.

```
awk '$9 == 503' /srv/logs/access.log | head
awk '$9 ~ /^5[0-9][0-9]$/' /srv/logs/access.log | head
```

The anchors matter the moment the pattern meets a wider field: applied to the
whole line, or to `$10`, an unanchored `/5../` happily matches a 5031-byte
response.

</details>

<details>
<summary>Hint 3 — counting things by key</summary>

The classic shell idiom, in order: extract the key, sort so equal keys are
adjacent, count runs, sort by count:

```
awk '$9 ~ /^5[0-9][0-9]$/ {print $3}' /srv/logs/access.log \
  | sort | uniq -c | sort -rn | head -5
```

`uniq -c` only collapses *adjacent* duplicates, which is why the first `sort`
is not optional.

awk can do the whole thing in one pass with an associative array, which is
faster on a file this size but no more correct:

```
awk '$9 ~ /^5[0-9][0-9]$/ {c[$3]++} END {for (k in c) print c[k], k}' /srv/logs/access.log \
  | sort -rn | head -5
```

For question 3 you need a per-minute key. `$4` is `[02/Aug/2026:09:14:33`, so
`substr($4, 14, 5)` is `09:14` — or use `cut -d: -f2,3` on that field.

</details>

<details>
<summary>Hint 4 — two ways to lose an hour</summary>

**`sort file > file`.** The shell truncates the redirect target *before* sort
runs, so this empties the file and then sorts nothing. Use `sort -o file
file`, which sort handles safely, or write somewhere else. The check
fingerprints the log specifically so you find this out in ten seconds rather
than at the end.

**`LC_ALL`.** Sorting and character classes go through the locale. On a big
file `LC_ALL=C sort` is often several times faster than the same sort under a
UTF-8 locale, and it also makes `[a-z]`-style ranges behave the way you
expect. It does not change any answer here — it changes how long you wait.

</details>

<details>
<summary>Solution</summary>

### q1 — how many 5xx

```
$ awk '$9 ~ /^5[0-9][0-9]$/ {n++} END {print n+0}' /srv/logs/access.log
8493
```

Compare with the line-matching answer:

```
$ grep -c 503 /srv/logs/access.log
202127
```

202,127 versus 8,493. `grep` is not broken — it answered the question you
asked, which was "how many lines contain these three characters anywhere".
Most of those lines are a 5031-byte response, or `/static/js/app.503.min.js`,
or `?q=503+error`.

### q2 — the noisiest customer

```
$ awk '$9 ~ /^5[0-9][0-9]$/ {print $3}' /srv/logs/access.log | sort | uniq -c | sort -rn | head -3
   1564 cust-00042
    139 cust-00036
    136 cust-00040
```

One customer is an order of magnitude above the pack, which is what a real
"one tenant is melting the service" incident looks like. Write just the id:

```
awk '$9 ~ /^5[0-9][0-9]$/ {c[$3]++} END {for (k in c) if (c[k] > b) {b = c[k]; who = k} print who}' \
  /srv/logs/access.log > /root/answers/q2
```

### q3 — the busiest minute

```
$ awk '{print substr($4, 14, 5)}' /srv/logs/access.log | sort | uniq -c | sort -rn | head -3
   1197 09:14
    300 21:17
    300 21:04
```

`09:14` served four times a normal minute. Baseline minutes sit near
240-300, so the spike is not subtle once you have the right key — and is
completely invisible if you look at hourly buckets, where it disappears into
~17,000 requests.

### Why this is a lesson at all

Every roadmap lists `awk`, `sed`, `sort` and `grep` under "Linux basics" and
then never asks you to answer a question with them. The skill is not the flag
syntax; it is:

1. **Decide what the unit of data is.** Here it is a field in a line, so the
   tool has to be field-aware. Reaching for `grep` first is the actual mistake
   — it is a line-matcher being asked a column question.
2. **Anchor your match.** `503` matches a path. `^5[0-9][0-9]$` on `$9`
   matches a server error. The difference is 202,127 lines versus 8,493.
3. **Pick the key, then count.** `sort | uniq -c | sort -rn` answers "which
   value occurs most" for any key you can extract, which is most of the
   questions anyone will ever ask you about a log.
4. **Know one footgun per tool.** For `sort` it is `sort f > f`. For `uniq` it
   is that it only sees adjacent lines. For `awk` it is that `$9` depends on a
   log format that can change under you — which is exactly why the answer to
   "should we keep parsing logs like this forever?" is no, and why Module 13
   exists.

</details>
