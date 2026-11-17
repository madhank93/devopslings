---
title: "Six benchmark runs, one capacity plan"
---

## The situation

The catalog relaunch re-indexes every product, and the indexer cluster has to
be sized for it. Each indexer node builds a batch of documents on its own,
then commits the batch to the shared index. Commits take the index's write
lock, and every commit also tells each of the other nodes that the index
changed.

Benchmarks run on the production-sized hardware, which is booked by the hour,
and this quarter's budget is six runs:

```
bash <lesson>/files/bench.sh 1 2 4 8 16 32
```

Each line is a node count and the commits a second the cluster sustained.
`bench.sh` refuses any other node count.

The plan has to say how many nodes to buy, and what the cluster does at that
size. "Somewhere between 8 and 32" is not a plan.

## The Universal Scalability Law

The `the-knee` lesson named the two effects. Here they become numbers. With
`X(1)` the throughput of one node:

```
X(N) = X(1) × N / (1 + σ(N − 1) + κN(N − 1))
```

- **σ** (sigma), **contention**: the share of the work only one node can do
  at a time. On its own it makes the curve flatten towards a ceiling. That
  is Amdahl's law.
- **κ** (kappa), **coherency**: a cost paid for every *pair* of nodes, such
  as keeping each other's caches in step. It grows with N², so past some
  point each node added makes the cluster slower.

With both fitted, the peak is at:

```
N* = sqrt((1 − σ) / κ)
```

Two coefficients from six runs is a fit, not a calculation: the runs are
noisy and the law is a model, so no choice of σ and κ goes through every
point. You want the pair that is closest to all of them.

## Your objectives

1. Run the six benchmarks.
2. Fit σ and κ to them.
3. Predict the node count where throughput peaks, and the throughput there.
4. Write `answers/usl.txt`:

```
sigma=<σ>
kappa=<κ>
peak_nodes=<N*, a whole number>
peak_per_s=<X at that many nodes>
cannot_tell=<one sentence: what the fit does not tell you>
```

## What you're being graded on

The check measures one node, 8 nodes and 32 nodes itself, and your σ and κ
must predict the last two within 10%. `peak_nodes` must be where your own
coefficients put the peak, and `peak_per_s` what they give there. Then it runs
the cluster at `peak_nodes`, a count the budget never let you measure, and
your prediction has to be within 10% of that run. `cannot_tell` must say
something the curve leaves out.

<details>
<summary>Hint 1 — the straight-line form</summary>

Divide `X(1) × N` by each measurement and subtract one:

```
y = N × X(1) / X(N) − 1  =  σ(N − 1) + κN(N − 1)
```

That is linear in σ and κ, with no intercept: a least-squares fit with two
columns, `N − 1` and `N(N − 1)`. Any spreadsheet's LINEST with the constant
turned off does it, and so does this, with your six measurements filled in:

```
docker compose exec -T checkout python3 - <<'PY'
runs = {1: 0, 2: 0, 4: 0, 8: 0, 16: 0, 32: 0}   # your commits a second
x1 = runs[1]
a = b = c = d = e = 0.0
for n, x in runs.items():
    if n == 1: continue
    y, u, v = n * x1 / x - 1, n - 1, n * (n - 1)
    a += u * u; b += u * v; c += v * v; d += u * y; e += v * y
s = (d * c - b * e) / (a * c - b * b); k = (a * e - b * d) / (a * c - b * b)
print("sigma", round(s, 4), "kappa", round(k, 5), "peak", round(((1 - s) / k) ** 0.5, 1))
PY
```

</details>

<details>
<summary>Hint 2 — what the model leaves out</summary>

σ and κ say how much the cluster loses to contention and coherency. Ask what
you would still need before you could make it scale better, and whether the
curve still holds if the batches, the index or the hardware change.

</details>

<details>
<summary>Solution</summary>

The six runs come out close to:

| nodes | commits/s |
|---|---|
| 1 | 43 |
| 2 | 85 |
| 4 | 162 |
| 8 | 267 |
| 16 | 277 |
| 32 | 236 |

The fit gives **σ ≈ 0.027** and **κ ≈ 0.0041**, so the peak is at
sqrt(0.973 / 0.0041) ≈ **15 nodes**, and X(15) = 43 × 15 / (1 + 0.027 × 14 +
0.0041 × 210) ≈ **290** commits a second.

```
sigma=0.027
kappa=0.0041
peak_nodes=15
peak_per_s=290
cannot_tell=It does not say why: which lock or resource causes the contention and the coherency cost, or how the curve moves if the workload changes.
```

A run at 15 nodes gives about 281: the prediction is 3% high. The law
smooths the top of the curve, and the real one is flatter there; anything
from 12 to 16 nodes is within a few percent of the peak, and the plan should
buy the cheaper end of that range.

### Why Amdahl alone gets it wrong

Fit σ alone and the 16-node run gives σ ≈ 0.1: a curve that rises towards
430 commits a second and never falls. The 32-node run is 15% slower than the
16, which no σ can produce. That second coefficient is the difference between
"buying more nodes is wasted money" and "buying more nodes makes it worse".

### What the fit does not tell you

The numbers describe the shape, not the cause. κ says something costs more
with every pair of nodes; it does not say it is the cache notification on
commit, and only that would tell you the fix (here: notify by broadcast
rather than node by node, or commit bigger batches less often). The fit also
holds only for the workload that was measured. A relaunch with larger
documents changes the 20ms of each node's own work, and with it the whole
curve.

This is Neil Gunther's Universal Scalability Law; his *Guerrilla Capacity
Planning* covers the fitting in depth.

</details>
