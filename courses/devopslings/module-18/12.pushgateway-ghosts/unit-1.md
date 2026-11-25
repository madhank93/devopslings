---
title: "the batch job that died three days ago"
---

## The situation

The nightly job exports a warehouse every night. Here a night is 20 seconds,
so it runs every 20 seconds. It has been failing for three nights:

```
tail /obs/logs/nightly.log
```

Its alert, in `/obs/prometheus/rules/nightly.yml`, is the one most people
write first:

```yaml
- alert: NightlyMissing
  expr: absent(nightly_last_success_timestamp_seconds{job="nightly"})
  for: 1m
```

and it has not fired. The metric is right there:

```
promq 'nightly_last_success_timestamp_seconds'
```

## Why the metric never goes away

A batch job is not running when Prometheus scrapes, so it cannot be scraped.
It **pushes** its results to the Pushgateway on the way out, and Prometheus
scrapes the Pushgateway. The Pushgateway is a cache, not a job: it serves the
last value pushed for each group (`job`, plus any grouping labels) until
someone deletes the group. It has no idea whether the job is alive.

So the metric a dead job last pushed is scraped every 5 seconds, forever,
with a fresh scrape timestamp. It never goes stale and `absent()` never
fires. Look at what the Pushgateway holds:

```
curl -s pushgateway:9091/api/v1/metrics | jq '.data[] | {labels, push: .push_time_seconds.metrics[0].value}'
promq 'push_time_seconds'
```

`push_time_seconds` is the Pushgateway's own record of when each group was
last pushed. It is the one number here that changes when the job stops.

The scrape job for the Pushgateway is in `/obs/prometheus/prometheus.yml`. It
sets `honor_labels: true`, so the series keep `job="nightly"` as the job
pushed it instead of being relabelled `job="pushgateway"`.

## Your objectives

1. An alert that pages when the nightly job has not completed a run for
   longer than its schedule allows. A run lands every 20 to 26 seconds.
2. No page while the job runs on schedule.

Edit the rule file, then `obs-reload`. To stop and restart the job's
successes yourself:

```
touch /obs/run/nightly.fault     # every run fails
rm /obs/run/nightly.fault        # runs succeed again
```

## What you're being graded on

- the job runs on schedule for 75 seconds: nothing pages
- the job fails every run: something pages within two minutes

<details>
<summary>Hint 1</summary>

`time() - push_time_seconds{job="nightly"}` is the age of the last push in
seconds.

</details>

<details>
<summary>Hint 2</summary>

Pick a threshold of about two schedules. One run late is normal; two missed
in a row is a failing job. In production, a job that runs nightly gets a
threshold of a day and a few hours.

</details>

<details>
<summary>Solution</summary>

```yaml
groups:
  - name: nightly
    rules:
      - alert: NightlyLate
        expr: time() - push_time_seconds{job="nightly"} > 60
        labels:
          severity: critical
      - alert: NightlyNeverPushed
        expr: absent(push_time_seconds{job="nightly"})
        for: 1m
        labels:
          severity: critical
```

The `absent()` alert stays for the case it does catch: a job that has never
pushed, or a Pushgateway that restarted and lost everything (it keeps no
data unless started with `--persistence.file`).

`time() - nightly_last_success_timestamp_seconds > 60` works too here,
because this job pushes only on success. A job that pushes on failure as well
(a `nightly_last_run_failed` gauge, say) updates `push_time_seconds` every
run, and then only its own success timestamp tells you it is failing.

### The ways this goes wrong

- **`absent()` of anything the job pushes.** The Pushgateway serves it
  forever.
- **A threshold at the schedule** (`> 20`, `> 25`). Pages between two
  healthy runs whenever one runs a little late.
- **`up{job="pushgateway"}`.** The Pushgateway is up. It always is.

</details>
