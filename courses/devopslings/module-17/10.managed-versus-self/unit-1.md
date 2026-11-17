---
title: "four services, buy or build"
---

## The situation

Four services, each run by a team that is asking whether to keep running it
or pay a provider to. The cases are in `/root/verdicts/services/`.

"Managed" is usually argued as if it were free: the provider runs it, so the
team does not. It is never free. Each managed offering takes a specific kind
of work off the on-call rotation, and adds something in return: a bill that
grows with use, a dependency that is expensive to leave, a limit on what you
are allowed to run, or distance between you and the thing. A verdict is a
trade between the two, for this service, with these numbers.

## Your objectives

For each service, write in `verdicts.txt`:

- `choice=` — `managed` or `self`
- `removes=` — what the managed option would take off the on-call rotation
- `adds=` — what the managed option would cost you

Fill in `removes=` and `adds=` whichever way you choose. For `managed`,
`adds=` is the price you accept. For `self`, it is the reason you decline.

## What you're being graded on

Each service has one right choice, one toil the case describes, and the
downside the case turns on. `adds=none` is rejected for every service.

<details>
<summary>Hint 1 — reading a case</summary>

Each case has a paragraph about the toil and one about the price. Ask what
woke someone up or took their days, and whether the provider would do that
part. Then ask whether the price, in money or in freedom, is worth it for
this service.

</details>

<details>
<summary>Hint 2 — the one that is not about money</summary>

Before weighing toil against cost, check that the managed offering can run
the service at all. A database that needs superuser cannot move to a
service that will not grant it, whatever the bill.

</details>

<details>
<summary>Solution</summary>

```
service-1: choice=managed removes=failover adds=cost
service-2: choice=self removes=patching adds=cost
service-3: choice=managed removes=capacity adds=lock-in
service-4: choice=self removes=backups adds=limits
```

1. The outage was a manual failover nobody had practised. A managed database
   fails over on its own. The price is 1.6 times the bill and a downtime
   migration to leave; either is a fair downside to name.
2. A day a month of upgrades, no pages, and a quote that costs more than the
   toil. Keep it.
3. Running out of disk at night and ordering servers a quarter ahead is
   exactly what a provider absorbs. The price is per-GB storage and
   per-GB restores, and moving petabytes back out later.
4. The extension is the point of the database, and no managed offering will
   run it. The toil it would remove does not matter.

</details>
