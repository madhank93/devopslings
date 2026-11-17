---
title: "Pick an SLI"
---

## The situation

The shop is getting an SLO, and an SLO is only as good as the indicator under
it. Three people proposed one each (`/ha/sre/candidates.txt`):

```
A  error rate: the share of all responses that were not 2xx
B  mean response time of all requests, in milliseconds
C  the share of requests to the customer pages (/, /cart, /orders) that
   succeeded within one second
```

To choose, look at yesterday. lb1 logged every request
(`/ha/sre/lb1-2026-11-13.log`), and support logged every ticket
(`/ha/sre/complaints.txt`). Three stretches of the day look alarming on a
graph. Customers only complained about one of them.

A log line, in HAProxy's `httplog` format:

```
198.51.100.23:41877 [13/Nov/2026:14:06:12.311] www app/web1 0/0/1/4210/4211 200 512 - - ---- 4/4/0/0/0 0/0 "POST /orders HTTP/1.1"
```

The fifth field is the timers `Tq/Tw/Tc/Tr/Ta`; the last, `Ta`, is the total
time in milliseconds. The sixth is the status code. The request is at the
end.

## Your objectives

1. Find the three alarming stretches of yesterday and say which one hurt
   customers.
2. Work out what each candidate does in each of the three.
3. Write `/ha/sre/sli`: an executable that reads an HAProxy log on stdin and
   prints one number, the share of good events among valid ones.

## What you're being graded on

The grader generates fresh 30-minute logs and pipes each into your `sli`:

- ordinary traffic must read at least 0.99;
- a scanner probing for admin pages, and the nightly bulk export, must also
  read at least 0.99, because nobody was hurt;
- checkout and cart taking seconds must read below 0.9;
- checkout and cart answering 503 must read below 0.9.

## Try it yourself

```
awk '$0 ~ /13\/Nov\/2026:14:1/' /ha/sre/lb1-2026-11-13.log | /ha/sre/sli
awk '{print substr($2, 14, 4)}' /ha/sre/lb1-2026-11-13.log | uniq -c   # requests per ten minutes
```

<details>
<summary>Hint 1 — where the three stretches are</summary>

Count requests and statuses per ten minutes, and look at the slowest `Ta`
values. One stretch has a lot more requests than usual, one has a few very
slow ones from a single address, and one is when the tickets were filed.

</details>

<details>
<summary>Hint 2 — what each candidate sees</summary>

A counts the scanner's 404s as failures and sees nothing at 14:00, because
every response there was a 200. B is dragged up by a handful of 10-second
export downloads that nobody waits for. C is close, but only if "customer
pages" really keeps the scanner and the export out, and "succeeded" means
both "not a server error" and "fast enough".

</details>

<details>
<summary>Solution</summary>

```bash
#!/bin/bash
awk '{
  split($(NF-1), p, "?"); path = p[1]
  if (path != "/" && path != "/cart" && path != "/orders") next
  split($5, t, "/"); valid++
  if ($6 < 500 && t[5] <= 1000) good++
} END { printf "%.4f\n", valid ? good / valid : 1 }'
```

### Good over valid

An SLI is a ratio of two counts: the events that went well, over the events
that count at all. The second count is where most of the judgement goes.
The scanner's requests and the export are real traffic, and both look bad on
a graph, but no customer was waiting for either, so they are not valid
events. Leaving them out is a decision about whose experience the SLO is
for, not a way of hiding failures.

A mean response time is not an SLI. There is no line where a request becomes
bad, so there is nothing to count, and nothing to spend an error budget on.
It is also pulled around by a few huge values, which is what the export did
to it.

### Measured where the customer is

The load balancer is close to the customer: it sees the slowness and the
errors whatever caused them. CPU on the app nodes, or a health check, would
have been flat at 14:00. The database was waiting on a lock, and nothing was
busy.

The one-second threshold is a choice too. Pick it from what customers
tolerate, then keep it fixed, because the SLO in the next lesson is built on
top of it.

</details>
