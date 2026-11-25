---
title: "the profiler that cost 15% of the service"
---

## The situation

The quotes service prices insurance quotes. Its container is limited to one
CPU. Last week continuous profiling was switched on, at 1000 samples a second
"for the best resolution", and throughput fell by about 15%. The incident
review proposes switching profiling off. Then the next CPU regression is
investigated the old way: without a profile.

```
$ cat /obs/quotes/profiling.ini
[pyroscope]
enabled = true
# samples per second
sample_rate = 1000
```

The service restarts when that file changes.

## What a sampling profiler costs

A sampling profiler wakes up `sample_rate` times a second, stops to read
every thread's stack, and records it. The cost is roughly **per sample**:
proportional to the rate, the number of threads, and how deep their stacks
are. This service has seventeen threads and deep stacks, and it shares its
one CPU with the profiler's own threads: every millisecond the profiler
spends is a millisecond the service does not get.

Resolution is about how many samples land in the window you look at, not
the rate. At 1000 Hz a five-minute window holds 300,000 samples; at 50 Hz,
15,000, which still ranks functions to a fraction of a percent. A function
that takes 5% of the CPU is in about 750 of them.

## Measuring overhead without fooling yourself

Module 20's `benchmark-traps` applies here in full:

- Same CPU for both runs: `taskset -c 0`, as the service's own limit is.
- Warm up before timing (`--bench` does a second of untimed work first).
- Alternate on and off, several times, and compare medians. A single pair
  of runs differs by a couple of percent by chance; that is the size of
  the effect you are trying to measure.

```
for i in 1 2 3; do
  taskset -c 0 python3 /obs/quotes/service.py --bench 5 --off
  taskset -c 0 python3 /obs/quotes/service.py --bench 5
done
```

`--bench` also prints `profiler_cpu_percent`: the CPU time of every thread
except the one doing the work, read from `/proc/self/task/*/stat`, as a share
of one CPU over the run. On a single CPU that is the overhead, measured
directly. The two numbers should agree; when they do not, trust neither until
you know why. Both read high while something else is busy on the machine, so
measure when it is quiet.

## Your objectives

1. Choose a sample rate, set it in `/obs/quotes/profiling.ini`, and keep
   profiling enabled.
2. Measure its overhead, profiler on against off, and write both to
   `/obs/answers/overhead.txt`:

   ```
   sample_rate=<samples per second>
   overhead_percent=<your measured throughput cost>
   ```

## What you're being graded on

Your measured overhead must be under 2%. The check runs the service on one
CPU at your rate and measures the profiler threads' share of its CPU, which
must be under 2%. Then it reads Pyroscope's profile of the service since it
restarted on your config: at least 100 samples, with the known hot function,
`risk_score`, in at least half of them.

<details>
<summary>Hint 1 — the shape of the curve</summary>

Measure three rates — 1000, 100 and something lower — and look at
`profiler_cpu_percent` for each. Double the rate, double the cost.

</details>

<details>
<summary>Hint 2 — how low is too low</summary>

The check needs 100 samples in roughly the first 25 seconds of the service
running at half duty. Below about 10 Hz there are not enough to rank anything.
Pyroscope's own default is 100.

</details>

<details>
<summary>Solution</summary>

On one CPU, per-sample cost makes the profiler's share almost exactly
linear in the rate:

| sample_rate | profiler CPU | quotes/s, on vs off |
|---|---|---|
| 1000 | ~13% | −13% |
| 100 | ~1.6% | −1 to −2% |
| 50 | ~0.8% | within noise |

```
[pyroscope]
enabled = true
sample_rate = 50
```

```
sample_rate=50
overhead_percent=0.9
```

At 50 Hz, a minute of the service at full load is 3000 samples, and
`risk_score` is in about nine tenths of them. 100 Hz passes too, closer to
the line; 1000 Hz bought resolution nobody was reading.

### Profiler overhead in practice

- The cost per sample grows with stack depth and thread count. A service
  with 500 threads pays much more per sample than this one; measure on the
  real thing.
- On a box with spare cores the profiler's threads run beside the service
  and throughput barely moves, but the CPU bill does. A CPU limit, as here,
  turns that cost into lost throughput.
- eBPF-based profilers (Pyroscope's eBPF agent, Parca, `perf`) sample from
  the kernel and do not run inside the process; they cost less per sample
  and see every process on the host, with less language-level detail.

</details>
