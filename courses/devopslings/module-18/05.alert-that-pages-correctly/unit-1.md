---
title: "the database went down, and the pager stayed quiet"
---

## The situation

db stopped answering for ten minutes last night. Prometheus fired every alert
it should have: `DatabaseDown`, and then shop's `ShopErrorRate` and
`ShopCartFailing` once shop's db-backed pages started failing. The pager never
went off. The alerts went to the ticket queue, and someone read them in the
morning.

The rules are in `/obs/prometheus/rules/shop.yml`. Where alerts go after they
fire is decided by Alertmanager, in `/obs/alertmanager/alertmanager.yml`:

```yaml
route:
  receiver: tickets
  group_by: [alertname]
  routes:
    - matchers: ['severity="page"']
      receiver: pager
```

The sink at `http://sink:8080` stands in for both receivers and records every
notification. Its path says which receiver sent it, `/pager` or `/tickets`:

```
curl -s sink:8080/notifications | jq '.[] | {path, status: .payload.status, alerts: [.payload.alerts[].labels.alertname]}'
```

## How Alertmanager handles an alert

1. **Routing.** The alert goes down the route tree. The first child route
   whose matchers match the alert's labels decides the receiver. If no child
   matches, the root's receiver gets it. `amtool config routes test` shows
   where a set of labels ends up:

   ```
   amtool config routes test --alertmanager.url=http://alertmanager:9093 severity=critical service=db
   ```

2. **Grouping.** Alerts with the same values for the `group_by` labels are
   put in one group, and a group becomes one notification. `group_wait` is how
   long a new group waits for more alerts before its first notification.
   `group_interval` is how long it waits before notifying about changes to it.

3. **Inhibition.** An `inhibit_rules` entry mutes alerts that match
   `target_matchers` while an alert matching `source_matchers` is firing. Use
   it for an alert that explains another one: when the database is down, the
   errors of the services that use it are not news.

Fixing only the routing sends the night's outage to the pager as three
pages, one per alert name, a few seconds apart. Each page wakes the on-call
engineer, and each one makes the outage look like a different problem.

## Your objectives

Edit `alertmanager.yml`, then run `obs-reload`:

1. Critical alerts reach the pager. Warnings stay in tickets.
2. A db outage sends **one** page, and that page names `DatabaseDown`, the
   cause, and not shop's symptoms.
3. A shop bug of its own, with db healthy, still pages, once.

Leave the alert rules as they are, and do not use silences: a silence hides
the next real outage too.

## What you're being graded on

The check routes each rule's labels with `amtool`, then breaks things and
counts what reaches `/pager`:

- **db outage**: db is stopped for about a minute. Exactly one page, naming
  `DatabaseDown`, without shop's alerts in it.
- **an unrelated outage during the db outage**: the check sends Alertmanager a
  critical `PaymentProviderDown` alert while db is down. It has to page.
- **shop bug**: shop fails most requests with db healthy. Exactly one page,
  naming shop's alerts.
- `WorkerQueueDepthHigh`, a warning, routes to tickets.
- no active silences, and `group_wait` under a minute.

The check runs both outages one after the other and takes several minutes.

<details>
<summary>Hint 1 — the route that never matches</summary>

Test where `DatabaseDown` goes:

```
amtool config routes test --alertmanager.url=http://alertmanager:9093 severity=critical service=db
```

It ends up in `tickets`. The child route matches `severity="page"`. Look at
the `severity` the rules actually set.

</details>

<details>
<summary>Hint 2 — three pages for one outage</summary>

With `group_by: [alertname]`, each alert name is its own group and sends its
own notification. Every alert here carries a `service` label. Grouping by
`service` puts shop's two alerts in one notification.

That still leaves db's page and shop's page. shop fails because db is down,
so mute shop's alerts while `DatabaseDown` fires:

```yaml
inhibit_rules:
  - source_matchers: ['alertname="DatabaseDown"']
    target_matchers: ['service="shop"']
```

Inhibition only works for alerts Alertmanager already holds. `DatabaseDown`
has to arrive before shop's alerts get sent. Its `for:` is shorter than
theirs, and a `group_wait` of some seconds covers the rest.

</details>

<details>
<summary>Solution</summary>

```yaml
route:
  receiver: tickets
  group_by: [service]
  group_wait: 30s
  group_interval: 5s
  repeat_interval: 1h
  routes:
    - matchers: ['severity="critical"']
      receiver: pager

# shop cannot work without db, so while db is down shop's alerts say nothing new.
inhibit_rules:
  - source_matchers: ['alertname="DatabaseDown"']
    target_matchers: ['service="shop"']
```

Three changes:

- **The route matches a value the rules set.** Nothing had
  `severity="page"`, so every alert fell through to the root receiver. The
  config was valid, and `amtool check-config` passed it. Only
  `amtool config routes test` shows that a route matches nothing.
- **Groups follow the thing that is broken.** `group_by: [service]` puts one
  service's alerts in one notification. Grouping by `alertname` sends one
  page per symptom.
- **The cause mutes its symptoms.** While `DatabaseDown` fires, shop's
  alerts are inhibited. When shop breaks on its own, nothing inhibits them,
  and they page.

`DatabaseDown` keeps firing for 45 seconds after db is back
(`keep_firing_for`), because shop takes a few seconds to recover and its error
rate is computed over 20 seconds. Without that, shop's alerts would page just
as the outage ends.

### The wrong fixes

- **Routing everything to the pager.** Warnings wake people up, and the
  pager gets ignored.
- **`group_by: ['...']`** (everything in one group). One page for every alert
  across every service, and a second, unrelated outage only updates the first
  one instead of paging.
- **An inhibit rule that targets every critical alert**, for example
  `target_matchers: ['severity="critical"']`. It passes for this outage, and
  while db is down it also mutes every unrelated critical alert, such as a
  payment provider failing at the same time. Target the alerts the cause
  explains, and nothing else.
- **A long `group_wait`.** It does batch the alerts, and the first page then
  arrives minutes late in every outage.
- **A silence.** It mutes the next outage as well, until it expires.

</details>
