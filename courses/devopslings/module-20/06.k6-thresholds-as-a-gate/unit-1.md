---
title: "A load test that has never failed a build"
---

## The situation

cart's pipeline ends in two stages, in `answers/pipeline.sh`:

```bash
echo "== stage: load test =="
docker compose exec -T k6 k6 run - < answers/load.js | tee answers/load-test.log

echo "== stage: promote =="
date +%s > answers/promoted
```

`answers/load.js` sends 50 requests a second at staging for 15 seconds and
prints k6's summary. Someone is supposed to read it. Last week's build went
out with this in its log:

```
http_req_duration..: avg=46ms  p(90)=168ms  p(95)=176ms
http_req_failed....: 2.52%
```

One request in eight got 150ms slower, and one in fifty failed. The test saw
all of it, and the pipeline promoted the build anyway, because nothing in
the pipeline reads the summary.

That build is on staging now. Run the pipeline and watch it promote:

```
bash answers/pipeline.sh
```

## Exit codes are the interface

A pipeline does not read output. It reads exit statuses, and a stage
passes when its command exits 0. Two things have to be true for a load test
to stop a pipeline:

1. **k6 has to exit non-zero when the numbers are bad.** It does that only
   for **thresholds**: pass/fail conditions on a metric, declared in
   `options`. With no thresholds, k6 exits 0 whatever it measured. When a
   threshold is crossed it exits 99.

   ```js
   thresholds: {
     http_req_failed: ['rate<0.01'],      // under 1% of requests fail
     http_req_duration: ['p(95)<100'],    // p95 under 100ms
   },
   ```

2. **The shell has to keep that status and act on it.** Bash runs the next
   line whatever the last one returned, unless `set -e` tells it to stop. A
   pipeline `a | b` returns `b`'s status, so `k6 run ... | tee log` returns
   `tee`'s 0 even when k6 returned 99, unless `set -o pipefail` is set.

The cart team's SLO is a p95 under 100ms with fewer than 1% of requests
failing. The healthy build runs at about 33ms p95 with no errors.

## Your objectives

Make the pipeline stop at the load test when the regressed build is on
staging, and promote the healthy build. Change `answers/load.js` and
`answers/pipeline.sh`. You can switch staging between the two with:

```
bash <lesson>/files/deploy.sh healthy      # or: regressed
```

## What you're being graded on

The check puts the regressed build on staging and runs `bash
answers/pipeline.sh`: it must exit non-zero and must not write
`answers/promoted`. Then it puts the healthy build there and runs it again:
it must exit 0 and promote.

<details>
<summary>Hint 1 — thresholds alone</summary>

Add thresholds and run the pipeline against the regressed build. k6 prints
`✗` next to the crossed threshold and an error saying thresholds were
crossed, and then the pipeline promotes anyway. Run `echo ${PIPESTATUS[@]}`
right after a `k6 ... | tee` line in an interactive shell to see the two
statuses: k6's 99 and tee's 0.

</details>

<details>
<summary>Hint 2 — where to set the line</summary>

Put the threshold between the two builds, with margin on both sides. A p95
of 100ms sits well above the healthy build's 33ms and well below the
regression's 176ms. A threshold at 40ms would catch the regression and fail
the healthy build on a noisy day, and a gate that fails good builds gets
bypassed within a week.

</details>

<details>
<summary>Solution</summary>

`answers/load.js`, in `options`:

```js
  thresholds: {
    http_req_failed: ['rate<0.01'],
    http_req_duration: ['p(95)<100'],
  },
```

`answers/pipeline.sh`, at the top:

```bash
set -euo pipefail
```

On the regressed build, k6 marks both thresholds crossed and exits 99.
`pipefail` makes the `k6 | tee` line return 99, `-e` stops the script there,
and promote never runs. On the healthy build both thresholds hold, k6 exits
0, and the pipeline carries on.

### Choosing thresholds

- **Gate on what users feel.** Error rate and a high percentile. An average
  hides exactly the one request in eight that got slower here: the
  regressed build's average is 46ms, which looks fine.
- **Tie them to the SLO.** If the SLO says p95 under 100ms, a staging test
  that allows 200ms is promoting builds the SLO will page about.
- **Leave margin for noise.** Staging is not production. A threshold right
  at the healthy build's number fails it at random, and a flaky gate trains
  people to rerun until green.
- **`abortOnFail`** ends the test as soon as a threshold is crossed, which
  saves time on long tests:
  `http_req_failed: [{ threshold: 'rate<0.01', abortOnFail: true }]`.

### Other ways the status gets lost

- `k6 run ... || true`, added once to get past a flaky run and never
  removed.
- `k6 run ...; echo "done"` as the last line of a CI step whose shell has no
  `-e`: the step's status is `echo`'s.
- Running k6 in a container with a wrapper that does not pass its exit code
  through.

Check each one the same way: run the stage against a build that should fail,
and look at the exit status, not the log.

</details>
