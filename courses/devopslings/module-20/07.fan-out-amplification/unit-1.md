---
title: "Ten fast calls make one slow page"
---

## The situation

The profile page is built from ten shards. To render a page it calls every
shard once, at `http://localhost:8221/shard/<n>`, and waits for all ten
answers.

Each shard is fast. A call takes about 10ms, and one call in a hundred, on any
shard, takes 400ms instead: a compaction, a cold cache, a busy host. The shard
team's dashboard shows a p99 of about 10ms, which is true: the slow calls are
exactly 1%, right at the edge.

The page's budget is a p99 under 200ms. Load-test it:

```
docker compose exec -T k6 k6 run - < answers/page.js
```

The p99 comes back near half a second.

## The arithmetic

A page is fast only if **all ten** of its calls are fast. Each one is fast 99%
of the time, and the calls are independent, so:

```
P(page is fast) = 0.99 × 0.99 × ... (ten times) = 0.99^10
P(page is slow) = 1 − 0.99^10
```

Work that number out. It is the share of pages that wait on a 400ms call, and
it is far more than 1%. A page that calls a hundred shards is slow 63% of the
time on the same shards. The tail of each backend becomes the body of the
page's distribution. This is why Dean and Barroso's *The Tail at Scale* says
that at high fan-out, a backend's p99 decides the frontend's median.

## The settings

The page reads two settings from `sandboxes/chaos-stack/.env`:

| Setting | Values |
|---|---|
| `FANOUT` | `sequential` calls shard 0, waits, then shard 1, and so on. `parallel` calls all ten at once and waits for the last. |
| `HEDGE_AFTER_MS` | If a call has not answered after this many milliseconds, send the same call again and use whichever answers first. Empty or `0` means never. |

Apply them with `bash <lesson>/files/deploy.sh`, from `sandboxes/chaos-stack`.

## Your objectives

1. Compute the share of pages that wait on at least one slow call, as a
   percentage to one decimal place, and write it in `answers/fan-out.txt`:

   ```
   slow_page_pct=<n>
   ```

2. Change the settings so the page's p99 is under 200ms at 30 pages a second.

## What you're being graded on

The check reads your percentage, then redeploys the page with your `.env` and
runs the lesson's own copy of `page.js`. Every page must be served, with a p99
under 200ms.

<details>
<summary>Hint 1 — parallel is not enough</summary>

Parallel calls make a page take as long as its slowest call instead of the sum
of all ten, so the median drops from about 110ms to about 15ms. The p99 barely
moves: the share of pages that contain a 400ms call is the same, because the
page still waits for it. Parallelism fixes the body of the distribution, not
the tail.

</details>

<details>
<summary>Hint 2 — hedging</summary>

A slow call is slow because of where it landed, not because of what it asked.
Sending the same call again after a short wait usually gets a fast answer:
the second call is slow only one time in a hundred too. Wait a little longer
than a normal call takes, so most calls never get a second copy.

</details>

<details>
<summary>Solution</summary>

`1 − 0.99^10 = 0.0956`, so `slow_page_pct=9.6`.

`.env`:

```
FANOUT=parallel
HEDGE_AFTER_MS=30
```

The page now waits about 10ms for nine of its calls. For a call that has not
answered after 30ms it sends a second copy, which answers in about 10ms, so
the slowest call takes about 40ms instead of 400. For a page to be slow, a
call and its hedge both have to be slow: one in ten thousand per shard. The
p99 drops to around 45ms.

### What hedging costs

Every hedge is an extra request. At 30ms only the slow calls, about 1%, get
one, so the shards carry about 1% more load. A hedge at 5ms would fire on
nearly every call and double the load on the shards for the same latency. Set
the delay near the backend's own p95 or p99, so it only fires on the tail.

Hedging assumes the call is safe to send twice. A read is. A write needs an
idempotency key, or it happens twice.

### Other ways out

- **Fan out less.** A page that needs ten shards because the data is spread
  across ten is paying for the layout. Co-locating what a page reads is the
  fix that removes the arithmetic instead of fighting it.
- **Cache.** A section served from cache does not call its shard, and only
  calls that happen can be slow.
- **Render without the straggler.** If a section is optional, give it a
  deadline and render the page without it.

</details>
