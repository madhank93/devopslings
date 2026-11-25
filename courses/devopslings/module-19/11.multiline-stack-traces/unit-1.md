---
title: "A traceback arrives in Loki as thirty lines, and only two of them say which report"
---

## The situation

reports renders reports on request. It logs with Python's `logging` module to
`/obs/logs/reports.log`, and the Collector tails that file into Loki, where
the stream is `{service_name="reports"}`.

When a render fails, reports logs the failure with its traceback:

```
2026-11-23 10:14:02,118 ERROR [req-ab12] report r-1f00ab12 failed
Traceback (most recent call last):
  File "/obs/apps/lab.py", line 49, in do_GET
    pages = render(rid, [] if q.get("fail") else [1])
  File "/obs/apps/lab.py", line 34, in render
    return render(report_id, data, depth + 1) + 1
…
ValueError: report r-1f00ab12: section 'totals' has no rows
```

That is one record. Python wrote it in one go. In Loki it is some thirty
entries, one per line. Search for the report and you get two of them, the
header and the last line. The frames in between say nothing about which
report they belong to.

The first guess is to find `Traceback` and read the lines after it. reports
serves several requests at once, so the lines after it in a query result can
belong to another request, and a query that returns only matching lines does
not return the frames at all.

reports' source is `/obs/apps/lab.py`; it runs in the `lab` container. The
Collector's config is `/obs/otel/collector.yaml`; saving it restarts the
Collector, and its output is in `/obs/logs/collector.log`.

## Records and lines

A log shipper reading a file sees bytes and newlines. Unless it is told
otherwise, a newline ends a record. Most of the time that is right. A
traceback, a pretty-printed JSON body or a Java exception with its `Caused by:`
chain is one record that spans many lines.

The fix belongs where the file is read, before the lines are separated from
each other. A **multiline** rule tells the reader how to recognise the first
line of a record. Everything up to the next first line is appended to the
record in progress. The Collector's `filelog` receiver has one:

```yaml
receivers:
  filelog/app:
    include: [/var/log/app.log]
    multiline:
      line_start_pattern: '<regex matching the first line of a record>'
```

There is also `line_end_pattern`, for formats whose records end with a
marker. Vector's `file` source has the same idea under `multiline`, with
`start_pattern`, `condition_pattern` and a `mode`.

Pick the pattern from what every first line has and no continuation line has.
In this file that is the timestamp. `^Traceback` is the tempting choice, and
it cuts in the wrong place: the header that names the report ends up on the
record before it, and every line after the exception is glued onto the
traceback.

A multiline record is held until the next first line arrives, or until
`force_flush_period` (half a second by default) passes, so the last record of
a burst still ships.

## Your objectives

Make every failure reports logs one record in Loki, header to exception, and
keep every other line a record of its own.

## What you're being graded on

The check makes three reports fail at the same moment, among the usual
traffic, then looks each one up in Loki:

- each failure is exactly one record, identical to what reports wrote to the
  file: the header line, the traceback, the exception
- the record holds nothing else, no line from another request
- the report's `started` line is still a record of its own

<details>
<summary>Hint 1 — the pattern</summary>

Every record reports writes starts with `%(asctime)s`, as
`2026-11-23 10:14:02,118 `. No traceback line does.

</details>

<details>
<summary>Hint 2 — quoting</summary>

In YAML, a single-quoted string keeps backslashes as they are, so
`'^\d{4}-'` reaches the regex engine unchanged. In a double-quoted string,
`\d` is an escape YAML does not know, and the Collector will not start.

</details>

<details>
<summary>Solution</summary>

```yaml
receivers:
  filelog/reports:
    include: [/obs/logs/reports.log]
    start_at: end
    multiline:
      line_start_pattern: '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3} '
    resource:
      service.name: reports
```

```
logcli query '{service_name="reports"} |= "failed"' --since=2m --limit=1
```

Now returns the header, every frame and the exception as one entry. A search
for the report or for the exception finds the whole thing.

### The ways this goes wrong

- **`line_start_pattern: '^Traceback'`.** The header naming the report is
  appended to whatever record came before it, and the lines after the
  exception, other requests' `started` and `done`, are appended to the
  traceback until the next one.
- **`line_start_pattern: '^\S'`.** It works for these frames, which are
  indented. `Traceback (most recent call last):` and `ValueError: …` are not
  indented, so they each start a record and the failure is cut in three.
- **Joining in Loki at query time.** LogQL has no way to reassemble entries:
  by then the lines are separate, and which ones belong together is gone.

</details>
