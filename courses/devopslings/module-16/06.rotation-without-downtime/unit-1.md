---
title: "Rotating the password drops requests"
---

## The situation

`orders` opens a Postgres connection for every request, with the credential
at `secret/orders/db` in OpenBao. `rotate.sh` changes that password:

```bash
psql -c "ALTER ROLE orders PASSWORD '$new'"
bao kv put secret/orders/db username=orders password="$new"
```

Every time it runs, a burst of requests fails with `password authentication
failed`. So it runs at 3 a.m. Last quarter it did not run at all, because
nobody wanted to be awake for it.

Running it at 3 a.m. does not make it safe. It makes the failures happen when
fewer people are watching. A rotation that is only safe at night does not get
run in an incident, at noon, which is when you need it.

## Your objectives

1. `rotate.sh` changes the database password, and afterwards the old one no
   longer works.
2. A rotation in the middle of steady traffic fails zero requests.

## Getting set up

The script is `scratch/rotation-without-downtime/rotate.sh`. Run it from
`sandboxes/ci-stack`:

```
bash ../../scratch/rotation-without-downtime/rotate.sh
```

Read `courses/devopslings/module-16/06.rotation-without-downtime/orders.py`
before you change anything. It is short, and two things in it decide this
lesson: how long orders keeps a credential before fetching it again, and
which fields of the secret it reads.

To watch it fail, run a request loop in a second terminal while you rotate:

```
while :; do curl -s localhost:18168/order; sleep 0.1; done
```

## What you're being graded on

The check puts four streams of requests on orders, runs your `rotate.sh` three
seconds in, and keeps the load on for three seconds after it finishes. Then:

- `rotate.sh` exited 0, within two minutes
- the credential now in OpenBao logs in to Postgres
- **zero requests failed**, including requests that got no answer at all
- the credential from before the rotation no longer logs in

`orders` must keep serving. Stopping it, or pausing it, during the rotation
fails requests, and they count.

<details>
<summary>Hint 1 — where the failures come from</summary>

orders caches the credential for 10 seconds. Postgres switches to the new
password the instant `ALTER ROLE` commits. For up to 10 seconds after that,
orders still holds the old password, and every login with it is refused.

Swap the two lines and it still fails, the other way round: orders can fetch
the new password before Postgres accepts it.

With one password there is no order that works. At every moment, some copy is
out of step with the database.

</details>

<details>
<summary>Hint 2 — two at once</summary>

What you need is a window where both the old and the new credential work, and
it has to last longer than any client's cache.

orders already supports that. Read `handle()`: if the secret has a
`previous_password`, a refused login is retried with it. Nothing has ever
written that field.

</details>

<details>
<summary>Hint 3 — the order of the steps</summary>

1. Publish both: `password` is the new one, `previous_password` the current one.
2. Wait until every reader has fetched that pair: longer than its cache.
3. Change the password in Postgres.
4. Remove `previous_password`.

Step 2 is the one people leave out, and it is the whole lesson.

</details>

<details>
<summary>Solution</summary>

```bash
#!/usr/bin/env bash
set -euo pipefail

bao()  { docker compose exec -T -e BAO_TOKEN=devopslings-root bao bao "$@"; }
psql() { docker compose exec -T db psql -U postgres -d app -v ON_ERROR_STOP=1 -qAt "$@"; }

cache=10   # orders' CRED_TTL
old=$(bao kv get -field=password secret/orders/db | tr -d '\r')
new=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')

bao kv put secret/orders/db username=orders password="$new" previous_password="$old" >/dev/null
sleep $((cache + 2))
psql -c "ALTER ROLE orders PASSWORD '$new'"
bao kv put secret/orders/db username=orders password="$new" >/dev/null
```

### The dual-read window

Every rotation has the same shape: **publish, wait, switch, retire.** For a
while two credentials must both be accepted. The wait has to cover the
slowest reader: a cache TTL, a connection pool's lifetime, a pod that only
reads its secret at startup. Rotate faster than the slowest reader refreshes
and that reader fails.

Look at what orders does in the window. It tries the new password first, it
is refused, and it tries the old one. It also tries the new one a second time,
because `ALTER ROLE` can land between the two attempts. Without that third
try, one request in a thousand fails at the moment of the switch. The check
finds it.

### The other way: two users

Postgres keeps one password per role, which is why orders has to try two. The
alternative is two roles, `orders_blue` and `orders_green`. Each rotation
gives the idle one a new password, publishes it as the current credential,
waits out the cache, then disables the other with `ALTER ROLE … NOLOGIN`.
Both are valid during the window, so no client has to try twice. This is
how managed rotation services do it ("alternating users"), and the check
accepts it.

### Why "the old one no longer works" is graded

The easy way to never drop a request is to never retire anything: add a new
password, leave the old one valid. That is not rotation. The old credential is
the one that may have leaked, and the point of rotating is that it stops
working. The window has two edges, and closing the second is as important as
opening the first.

### Rotation you can run at noon

Once rotation is safe under load, it can be routine: weekly, or after every
departure from the team, or from a pipeline. That is what makes the next
incident short. When a credential leaks, the response is the same script,
run now. The previous lesson goes further: credentials so short-lived that
they hardly need rotating.

</details>
