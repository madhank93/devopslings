---
title: "Five tests, one service"
---

## The situation

`quote` prices shipping for the checkout page. Production sends it about
**100 requests a second** at the daily peak. Every release runs the same load
test, `answers/ramp.js`: up from 10 to 150 a second, hold, check p95 and
errors. It has never failed.

And every afternoon, after a few hours of steady traffic, `quote` falls over
for a moment, comes back, and a batch of checkouts error. Nobody can
reproduce it, because the load test passes.

One test shape answers one question. A ramp asks "does it cope at this
rate?", and quote does. Production is asking something else.

Run a test from `sandboxes/chaos-stack` with:

```
bash <lesson>/files/run.sh ramp
```

It runs `answers/<shape>.js` in k6 and saves the summary beside it as
`answers/<shape>.json`. quote's own view, its memory and how many times it
has been restarted:

```
docker compose exec -T checkout python3 -c "import urllib.request as u; print(u.urlopen('http://localhost:8250/stats').read().decode())"
```

## The five shapes

| shape | load | what it finds |
|---|---|---|
| **ramp** | up gradually to a target | where latency starts to bend |
| **soak** | normal load, held for a long time | anything that accumulates: leaks, filling disks, growing queues |
| **spike** | a sudden jump far past normal, then back | how it copes with a burst, and whether it recovers |
| **stress** | well above normal, held | how it behaves past its comfort zone |
| **breakpoint** | keeps rising until it fails | the actual capacity, as a number |

In production a soak runs for hours. This lab's clock is compressed: here a
soak is anything over 75 seconds at normal load, and the other tests stay
under 40 (the breakpoint under 60).

## Your objectives

1. Write `soak.js`, `spike.js`, `stress.js` and `breakpoint.js` in
   `answers/`, with an arrival-rate executor (lesson 04). `ramp.js` is the
   pattern.
2. Run all five with `run.sh`.
3. Write `answers/shapes.txt`:

```
only_one=<the shape that found a failure no other shape found>
failure=<what failed>
breakpoint_rps=<the rate at which quote starts failing>
```

## What you're being graded on

Each script must have its shape:

- **soak**: 75s or more, at 50 to 150 a second
- **spike**: a jump to 400 a second or more, at least fourfold, within 5s
- **stress**: 200 a second or more held for at least 15s
- **breakpoint**: a `ramping-arrival-rate` to 600 a second or more, with a
  threshold that has `abortOnFail: true`

Each must have been run since the lesson started. The soak must have failed,
and `shapes.txt` must name the shape, what failed, and quote's breaking
point, within 240 to 460 a second.

<details>
<summary>Hint 1 — a breakpoint that stops itself</summary>

```js
thresholds: {
  http_req_failed: [{ threshold: 'rate<0.01', abortOnFail: true }],
},
```

k6 stops the run as soon as failures pass 1%. The summary's
`http_reqs.count` divided by `http_reqs.rate` is how long it ran; from that
and your stages, work out the rate it had reached.

</details>

<details>
<summary>Hint 2 — what to watch during the soak</summary>

Poll `/stats` every few seconds while the soak runs, in a second terminal.
Then read the end of quote's log:

```
docker compose exec -T checkout tail /srv/load-shapes/quote.log
```

</details>

<details>
<summary>Solution</summary>

The four scripts are in the lesson's `solution/` directory. What each one
shows:

- **ramp** (to 150/s): passes. p95 around 60ms.
- **stress** (250/s for 20s): passes. Busy, but inside capacity.
- **spike** (100 to 600/s in 2s): a burst of 503s while quote's queue is
  full, then it recovers as soon as the spike passes.
- **breakpoint** (+20/s every second): aborts at around 320 to 400 a second,
  with 503s. 16 workers at 50ms each finish 320 a second at most.
- **soak** (100/s for 80s): quote's memory climbs by 2MB every second.
  At around 110MB the platform kills it; it restarts a second later, and the
  requests in between fail.

```
only_one=soak
failure=quote leaks memory under steady traffic: after about a minute it passes its limit, is killed and restarts, and requests fail while it is down.
breakpoint_rps=320
```

The spike, stress and breakpoint failures are the same failure, running out
of workers, reached three ways. The leak is different: it does not depend
on how fast requests arrive but on how long they keep arriving. quote keeps
a duplicate filter for every second that sees traffic, and only clears them
after 2 seconds of silence. A release test of 25 seconds never gets there.
Production at peak has no silent seconds for hours.

### Choosing shapes

Every shape is a hypothesis about how production fails. A ramp before every
release is a good default because it is quick; a soak overnight, a spike
before a known launch, and a breakpoint whenever capacity planning needs a
number are what catch the rest. The tests that run least often are the ones
that find the failures nobody has seen yet.

</details>
