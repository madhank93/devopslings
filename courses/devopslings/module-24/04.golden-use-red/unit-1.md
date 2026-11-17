---
title: "Golden signals, USE and RED"
---

## The situation

Three ways of looking at a system, and each was built to answer one
question:

| Method | Looks at | Answers |
|---|---|---|
| **RED** — rate, errors, duration | a service, from its callers' side | are the people calling this getting good answers, quickly? |
| **USE** — utilization, saturation, errors | each resource: CPU, memory, disk, network | which resource is the bottleneck? |
| **The four golden signals** — latency, traffic, errors, saturation | a user-facing system | RED, plus "how full is it", in one dashboard |

It is 10:25 and checkout is slow. `/ha/sre/claims.txt` has four people's
explanations, each with a real graph behind it. All four graphs are
accurate. Two of the four conclusions do not follow from them, because the
method behind the graph cannot answer the question being asked.

You have the shop's requests (`/ha/sre/shop-requests.log`, HAProxy httplog,
as in lesson 1) and pg1's resource samples (`/ha/sre/pg1-use.csv`).

## Your objectives

Fill in `/ha/answers/use-red.txt`:

1. RED for the shop's customer pages from 10:15:00 to 10:29:59: rate per
   second, error percentage (5xx), and p99 in milliseconds. And the minute
   customers started to hurt.
2. USE for pg1: which resource is saturated.
3. Which claims used a method that cannot answer their question.

## What you're being graded on

The numbers are recomputed from the data: the rate and p99 within 5% and
10%, the error percentage within 0.3 points, the minute within one. The
resource and the claims must be exact.

## Try it yourself

```
awk '{split($5, t, "/"); print substr($2, 13, 5), t[5]}' /ha/sre/shop-requests.log | sort -k2 -n | tail
column -s, -t /ha/sre/pg1-use.csv | sed -n '1p;70,76p'
```

<details>
<summary>Hint 1 — utilization is not saturation</summary>

A resource can be 93% utilized and fine, if nothing is waiting for it. A
resource can be 88% utilized and the bottleneck, if work is queueing in
front of it. USE reads all three columns per resource, and saturation —
the queue — is the one that says "this is where requests wait".

</details>

<details>
<summary>Hint 2 — which question is each claim answering?</summary>

For each claim, write down the question it answers ("are customers fine?",
"is pg1 the bottleneck?") and the method its evidence comes from. RED's
evidence is about requests; USE's is about resources. A claim is
mismatched when its evidence comes from the method that cannot see the
thing its question is about.

</details>

<details>
<summary>Solution</summary>

```
rate_per_second: (about 1)
error_percent:   (about 0.05)
p99_ms:          (about 8900)
customers_hurting_since: 10:12
saturated_resource: disk
mismatched_claims: A D
```

The numbers vary with the generated data.

**A** uses USE on the app nodes to answer a RED question. Their CPU is
idle because they are waiting on the database; idle hosts are exactly what a
stalled service looks like from inside. Only measuring requests answers
"are customers fine?".

**D** uses RED on pg1 to answer a USE question. A database whose disk is
queueing still answers every query, with no errors, at the usual rate. RED
sees a service from the outside and cannot tell "slow because the disk
queue is 14 deep" from "slow because the query changed". USE on pg1's disk
can.

**B** and **C** are each the right method for their question, and together
they are the whole incident: customers hurt from 10:12 (RED), because
pg1's disk saturated at 10:12 (USE).

### Golden signals

The four golden signals are RED plus saturation, for a user-facing system.
They are what goes on the first dashboard: traffic, errors and latency say
whether users are hurting, and saturation says how close the system is to
the point where they will. When the first dashboard goes red, USE is what
you do next, resource by resource, to find out why.

</details>
