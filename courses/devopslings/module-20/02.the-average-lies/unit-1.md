---
title: "The average is green"
---

## The situation

The account-profile API has one latency target on the team dashboard:
average response time under **300ms**. It reads about 230ms, and it has been
green all week.

Support disagrees. They have a queue of users who say their profile page
spins for seconds, every time, and they have stopped believing the dashboard.

The API's latency is a Prometheus histogram,
`profile_request_duration_seconds` (job `profile`), with buckets at 50ms,
100ms, 200ms, 500ms, 1s, 2s and 5s. Every number you need is in it. Run
queries from the box with `promq '...'`.

One more thing you know about the system: each user's profile lives on one
session-store shard, so all of a user's requests go to the same place, and
users make roughly the same number of requests each. The share of slow
*requests* is the share of slow *users*.

## How a mean hides people

A mean adds everything up and divides. It cannot tell "every request took
230ms" from "most took 110ms and a few took two seconds": both give the same
number. A dashboard built on it stays green while a slice of users has a
broken service, as long as the slice is small enough and the rest are fast
enough to pay for it.

The distribution does not average anything away. A histogram counts how many
requests fell at or under each bucket boundary, so the questions support is
asking ("how many people is this happening to?") have a direct answer.

## Your objectives

1. Compute the mean latency over the last minute from the histogram, to see
   the number the dashboard shows.
2. From the buckets, work out what share of users get a response slower than
   one second.
3. Write `/obs/answers/average.txt`:

```
mean_ms=<the mean, in milliseconds>
affected_users_pct=<the percentage of users slower than 1s>
```

## What you're being graded on

The check computes both from Prometheus over the last minute. Your mean has to
be within 10%, and your share within 0.6 percentage points.

<details>
<summary>Hint 1 — the mean</summary>

A histogram exports `_sum` (total seconds) and `_count` (requests) beside its
buckets. Rate both over a window and divide:

```
promq '1000 * sum(rate(profile_request_duration_seconds_sum[1m])) / sum(rate(profile_request_duration_seconds_count[1m]))'
```

</details>

<details>
<summary>Hint 2 — reading buckets</summary>

Look at all of them at once:

```
promq 'sum by (le) (rate(profile_request_duration_seconds_bucket[1m]))'
```

Each `le` bucket counts requests *at or under* its bound, so the counts only
grow as `le` rises, and `le="+Inf"` is every request. Requests slower than 1s
are the total minus the `le="1.0"` bucket.

</details>

<details>
<summary>Solution</summary>

```
promq '100 * (1 - sum(rate(profile_request_duration_seconds_bucket{le="1.0"}[1m])) / sum(rate(profile_request_duration_seconds_count[1m])))'
```

```
mean_ms=230
affected_users_pct=5.9
```

About **6% of users**, one in seventeen, wait between 1.2 and 2.8 seconds on
every request. Three of the fifty session-store shards sit on a node that is
swapping. Every user on those shards has a broken product; everyone else has
a fast one. There is no user anywhere near 230ms.

### What should be on the dashboard instead

- **A percentile, chosen to the size of slice you care about.** The p95 here
  is 1.4s, so it would have gone red. The p90 is 220ms and would have stayed
  green: a percentile only sees a problem that affects more requests than it
  leaves out.
- **Better: the share of requests over a threshold**, the query in this
  solution. "6% of requests took over a second" is a sentence support,
  engineering and the business all read the same way, and it is the shape an
  SLO takes (module 24).

A mean is still useful for capacity: total work divided by requests is what
Little's Law needs. It is the wrong number for "is anyone having a bad
time?".

</details>
