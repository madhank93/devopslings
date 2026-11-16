---
title: "the backup alert that could not fire"
---

## The situation

The backup job exports one number, when its last backup completed:

```
promq 'backup_last_success_timestamp_seconds'
```

and one alert watches it, in `/obs/prometheus/rules/backup.yml`:

```yaml
- alert: BackupStale
  expr: time() - backup_last_success_timestamp_seconds{job="backup"} > 30
  for: 10s
```

Backups complete every 10 seconds here, so 30 seconds without one is late.
The alert is correct. Last month the backup job's exporter died, backups
stopped with it, and three days passed before anyone noticed. BackupStale
never fired.

## Why it stayed quiet

When a scrape fails, Prometheus marks every series that target exposed as
**stale**. From the next evaluation on, the series is not there, not zero
and not its old value. Try it while backup is stopped:

```
promq 'up{job="backup"}'                                  # 0: the target is down
promq 'backup_last_success_timestamp_seconds'             # empty
promq 'time() - backup_last_success_timestamp_seconds > 30'   # empty
```

An alert fires for each series its expression returns. `time() - X > 30`
with no `X` returns nothing, and nothing never crosses a threshold. A
threshold alert can only say "the number is bad". It cannot say "there is
no number".

## absent()

`absent(v)` is the opposite: empty while `v` has a series, and one series
with the value 1 when it has none.

```
promq 'absent(backup_last_success_timestamp_seconds{job="backup"})'
```

`absent_over_time(v[1m])` does the same over a window: 1 only when `v` had
no sample at all in the last minute.

Data goes missing for ordinary reasons too. A deploy restarts the exporter,
a scrape times out, a pod moves. Each leaves a gap of a few seconds to a
minute. An alert that pages on the first missing sample pages on every
deploy, and a pager that goes off on every deploy gets ignored on the day
it matters. `for:` makes an alert wait: the expression has to stay true
that long before the alert fires, and until then it is **pending**.

## Your objectives

1. Keep `BackupStale`. Backups that stop completing while the exporter keeps
   reporting are still a failure, and it is the alert that sees them.
2. Add an alert that fires when backup's data is missing.
3. A 15-second deploy of the exporter must not page. An exporter that stays
   dead must page within two minutes.

Every alert goes to the pager. Edit the rule file, then `obs-reload`.
`promtool check rules /obs/prometheus/rules/backup.yml` checks it first.

To try it yourself, stop and start backup's exporter:

```
touch /obs/run/backup.down; sleep 60; rm /obs/run/backup.down
promq 'ALERTS'
curl -s sink:8080/notifications | jq '.[] | {status: .payload.status, alerts: [.payload.alerts[].labels.alertname]}'
```

## What you're being graded on

- `BackupStale` is still loaded
- backup's exporter stops for 15 seconds and starts again: nothing pages
- backup's exporter stops and stays stopped: something pages within two
  minutes
- backups stop completing while the exporter keeps reporting: something
  pages within 90 seconds

The check stops and starts backup's exporter itself and takes several
minutes.

<details>
<summary>Hint 1</summary>

Leave BackupStale as it is and add a second rule to the same group whose
expression is `absent(...)` of the metric BackupStale reads, with the same
`job="backup"` selector.

</details>

<details>
<summary>Hint 2 — how long to wait</summary>

The `for:` has to be longer than a deploy's gap, including the scrape
interval on either side of it, and short enough that a dead exporter is
noticed. Here a deploy is 15 seconds and the deadline is two minutes:
anything from about 30 seconds to a minute works. In production, with a
1-minute scrape interval, 5 to 10 minutes is common.

</details>

<details>
<summary>Solution</summary>

```yaml
groups:
  - name: backup
    rules:
      - alert: BackupStale
        expr: time() - backup_last_success_timestamp_seconds{job="backup"} > 30
        for: 10s
        labels:
          severity: critical
        annotations:
          summary: no backup has completed in 30 seconds

      - alert: BackupMetricsMissing
        expr: absent(backup_last_success_timestamp_seconds{job="backup"})
        for: 45s
        labels:
          severity: critical
        annotations:
          summary: nothing reports when the last backup completed, so BackupStale cannot fire
```

`absent_over_time(backup_last_success_timestamp_seconds{job="backup"}[1m])`
with no `for:` works too: the window is what rides out the deploy.

`absent()` returns a series with only the labels it can read off equality
matchers in its selector, here `job="backup"`. It cannot know an `instance`
it never saw, so put the labels routing needs in the alert's `labels:`.

### The ways this goes wrong

- **`absent(up{job="backup"})`.** A target that is down still has an `up`
  series, with the value 0. `absent(up)` fires only when the target is gone
  from the config altogether. To alert on a down target, use
  `up{job="backup"} == 0`.
- **No `for:`, or a short one.** Pages on every deploy.
- **A long `for:`** (`10m`, `1h`). Never pages on a deploy, and leaves
  backups unwatched for that long whenever the exporter dies.
- **Replacing BackupStale with the absent alert.** Now a dead exporter
  pages, and an exporter that keeps reporting the same old timestamp does
  not.
- **`absent(backup_last_success_timestamp_seconds)` with no selector**
  works today and stops working the day a second job exports a metric with
  that name.

</details>
