---
title: "A thousand requests, three numbers"
---

## The situation

Last night's load test sent 1,000 requests to search and recorded how long
each one took. The durations, in milliseconds and in the order the requests
were sent, are in `/obs/answers/durations.txt`:

```
head /obs/answers/durations.txt
```

Prometheus has the same numbers: one series per request,
`search_test_request_duration_ms{request="0001"}` up to `"1000"`.

The report everyone reads quotes three numbers: p50, p95 and p99. Before you
trust a percentile anyone else computes, compute one yourself.

## What a percentile is

Sort the durations from fastest to slowest. The **p95** is the duration that
95% of the requests are at or below: with 1,000 requests, the 950th in the
sorted list. The p50 is the 500th, the median, and the p99 the 990th.

That makes a percentile a statement about requests, not about time: "p99 is
2 seconds" means 1% of the requests took longer than 2 seconds. Which 1%, and
how much longer, the number does not say.

Tools disagree slightly at the edges. Some take the value at the rank, some
interpolate between it and its neighbour. On 1,000 values the difference is
small, and any of them counts here.

## Your objectives

1. Compute p50, p95 and p99 by hand from `durations.txt`. `sort -g` and
   `sed -n 950p` are enough.
2. Get the p99 from Prometheus with one PromQL expression, and check it
   agrees with yours.
3. Count how many of the 1,000 requests were slower than your p99.
4. Write `/obs/answers/percentiles.txt`:

```
p50=<ms>
p95=<ms>
p99=<ms>
worse_than_p99=<a count of requests>
query=<the PromQL expression>
```

## What you're being graded on

Your three percentiles must be the right ranks in the sorted data, your count
must match the data, and your query, run against Prometheus, must return a
single value that is the p99.

<details>
<summary>Hint 1 — by hand</summary>

```
sort -g /obs/answers/durations.txt | sed -n 950p
```

`sort -g` sorts numerically; plain `sort` sorts `1000` before `200`.

</details>

<details>
<summary>Hint 2 — by query</summary>

The 1,000 values are 1,000 series at one moment, so the percentile runs
*across series*: that is an aggregation operator, like `sum` or `avg`, that
takes the quantile as its first argument. Try it with `promq '...'`.

</details>

<details>
<summary>Solution</summary>

```
s=$(sort -g /obs/answers/durations.txt)
sed -n 500p <<<"$s"; sed -n 950p <<<"$s"; sed -n 990p <<<"$s"
```

```
p50=130.6
p95=923.7
p99=1953.8
worse_than_p99=10
query=quantile(0.99, search_test_request_duration_ms)
```

Prometheus says 1953.85: it interpolates at rank 0.99 × 999 = 989.01,
counting from zero, a hundredth of the way from the 990th value to the 991st.

### What the three numbers say

- **p50 = 131ms**: the typical request is fast.
- **p95 = 924ms**: one request in twenty took nearly a second. The jump from
  131 to 924 says there is not one population here but two: the normal
  requests, and a slow group that waited on something.
- **p99 = 1,954ms**, and **10 requests** were slower than that. The p99 tells
  you nothing about those ten: the slowest was 2.4 seconds, and it could have
  been 30.

The mean of the same data is 218ms, a duration almost no request actually
had: it sits between the two groups. The next lesson is about what that does
to a dashboard.

</details>
