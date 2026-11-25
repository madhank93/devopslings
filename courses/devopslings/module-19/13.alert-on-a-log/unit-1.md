---
title: "The payments page goes off for every declined card, three times over"
---

## The situation

payments runs as three pods. Each one logs JSON records to Loki, in the
stream `{service="payments", pod="…"}`:

```json
{"level": "info", "msg": "payment captured", "order_id": "ord-4410923", "amount": 120}
{"level": "info", "msg": "processor returned a retryable error, retried", "order_id": "ord-…", "attempt": 2}
{"level": "error", "msg": "payment failed", "order_id": "ord-…", "reason": "card declined by issuer"}
```

The team wanted a page when payments start failing, and wrote this Loki
ruler rule in `/obs/loki-rules/fake/rules.yaml`:

```yaml
- alert: PaymentsErroring
  expr: sum by (pod) (count_over_time({service="payments"} |= "error" [1m])) > 0
```

It pages all day. Twelve minutes ago the card processor really did time out
for three minutes, and the pager went off three times at once.

Loki has the last thirty minutes of payments' logs, outage included. Loki's
ruler rereads the rules directory every 5 seconds and sends alerts to
Alertmanager, whose pages land in `sink`
(`curl -s sink:8080/notifications | jq`).

## Alerting on logs

Loki's ruler runs LogQL metric queries on a schedule, the way Prometheus runs
PromQL. A rule file has the same shape as Prometheus's: `alert`, `expr`,
`for`, `labels`, `annotations`. A rule fires for each series its expression
returns, and each series becomes one alert, with that series' labels.

That gives three questions to answer about any rule.

**What does it count?** `|= "error"` matches the text "error" anywhere in the
line, including in a message about an error that was retried and succeeded.
If the record has a level, filter on it: `| json | level="error"`.

**How much is too much?** `count_over_time(...[1m]) > 0` is true for a minute
after any single error. A declined card is a failure, and it is the
customer's, not the system's. The thing worth waking someone for is a
*rate*: `rate({…} … [2m])` is failures per second, averaged over two
minutes, and a threshold on it separates "one card" from "the processor".
`for: 30s` adds that it has to stay that way for half a minute before the
alert fires.

**What is one alert?** `sum by (pod)` keeps a series per pod, so an outage
hitting every pod is three alerts. Alertmanager may bundle them into one
notification, but they are still three alerts, each paging, resolving and
being silenced on its own. Keep only the labels that make two alerts mean
two different problems. Here an outage is one problem, whichever pods it
hits.

Try an expression against the history before you put it in a rule. As a
range query it shows when it would have been true:

```
logcli query '<expr>' --since=30m --step=15s
```

## Your objectives

Change the rule so that payments page when they are failing at a rate that
means an outage, once for the outage, within two minutes of it starting,
and never for a single failure or for the retried errors.

## What you're being graded on

The check reads your rules from `/obs/loki-rules/fake/` once Loki's ruler has
loaded them, then:

- replays a quarter of an hour of payments' logs from three new pods into
  Loki: declined cards at minutes 2, 5 and 8, and retried errors all along,
  then every pod failing from minute 10 to 13. It runs your rule's expression
  over the replay, holding each result for the rule's `for`.
  - nothing may fire before minute 10
  - something has to fire by minute 12, and it has to be one alert
- then fails payments live, and expects Loki's ruler to fire that one alert
  and Alertmanager to have it

<details>
<summary>Hint 1 — the numbers</summary>

The outage runs at about 90 failures a minute across the pods; a declined
card is one. Retried errors are about a dozen a minute, at info level. Any
threshold well between those works.

</details>

<details>
<summary>Hint 2 — loaded or not</summary>

`curl -s loki:3100/prometheus/api/v1/rules | jq` shows what the ruler has, its
state and its alerts. A rule file the ruler cannot parse is not there, and
the reason is in Loki's log, not in the API.

</details>

<details>
<summary>Solution</summary>

```yaml
groups:
  - name: payments
    rules:
      - alert: PaymentsFailing
        expr: sum(rate({service="payments"} | json | level="error" [2m])) > 0.1
        for: 30s
        labels:
          severity: page
        annotations:
          summary: payments are failing at {{ $value | humanize }}/s across all pods
```

`0.1` per second over two minutes is twelve failures, ten times anything a
run of bad cards produces and a seventh of the outage's rate. The two-minute
window and the 30-second `for` together page about 40 seconds into an
outage. `sum` with no `by` makes it one series, and so one alert.

### The ways this goes wrong

- **Adding `for: 1m` to the original.** A single error is in a one-minute
  window for exactly one minute, so it pages or not depending on when the
  ruler happens to evaluate. And it still pages per pod.
- **`|= "error"` with a threshold.** The retried errors are steady and they
  are info, so the threshold has to sit above them, and then it is
  measuring the wrong thing.
- **`count_over_time(...[30m]) > 5`.** Quiet until a busy afternoon brings
  six declined cards inside half an hour, and after an outage it keeps
  firing for half an hour.
- **`sum by (pod)`, or `by (order_id)`.** One alert per value. `by (order_id)`
  is worse: every failed payment is its own alert.

</details>
