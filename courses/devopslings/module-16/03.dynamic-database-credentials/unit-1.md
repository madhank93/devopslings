---
title: "Four services share one database password"
---

## The situation

`billing`, `orders`, `shipping` and `reports` all log in to Postgres as `app`.
The password is in OpenBao at `secret/shared/db`, so at least it is not in a
file. It was set in 2019.

Last week a debug log in `reports` printed its connection string. The fix on
the table is the usual one: change the password now, and every quarter from
now on.

Think about what that change does. It is one password in four services. You
cannot change it for `reports` without changing it for everyone, which means
all four restart at once. And between leaks, the quarter-old password is just
as valid as a fresh one. A quarterly rotation shortens nothing about the next
leak.

## Your objectives

1. Each service gets a database credential of its own, issued by OpenBao, with
   a lease.
2. Revoking one service's lease cuts that service off from the database, and
   no other.

## Getting set up

```
bao() { docker exec -i -e BAO_TOKEN="${BAO_TOKEN:-devopslings-root}" devopslings-ci-stack-bao-1 bao "$@"; }
curl localhost:18161/health   # billing; orders, shipping, reports are 18162-18164
```

`/health` opens a new connection and reports who it logged in as, and the
lease if there is one.

What is already there:

- In Postgres (database `app`, host `db`), the group role **`app_rw`** holds
  what the services need on the `ledger` table. A login role **`bao`**,
  password `bao-admin-pw`, may create roles, grant them `app_rw` and end their
  sessions. It is not a superuser.
- In OpenBao, each service has its own token. It may read `secret/data/shared/db`
  and `database/creds/<its own name>`.
- In `sandboxes/ci-stack/.env`, `BILLING_DB_CREDS` and its siblings say which
  OpenBao path each service reads its credential from. Change them, then
  `docker compose up -d` from `sandboxes/ci-stack`.

A service fetches its credential once, on its first request, and keeps it.

## What you're being graded on

The check recreates all four services, so each fetches a credential from
your configuration as it is now. Then:

- every service reaches the `ledger` table
- no two log in as the same user
- every credential has a lease, under `database/creds/<service>/`
- the check revokes `orders`'s lease: `orders` must lose the database, and the
  other three must not
- `orders` is recreated afterwards, so it gets a fresh credential

<details>
<summary>Hint 1 — the database secrets engine</summary>

OpenBao can log in to Postgres as `bao` and create a user on demand. Three
steps: enable the engine, tell it how to connect, and define a role for each
kind of credential it may issue.

```
bao secrets enable database

bao write database/config/app \
  plugin_name=postgresql-database-plugin \
  connection_url='postgresql://{{username}}:{{password}}@db:5432/app?sslmode=disable' \
  username=bao password=bao-admin-pw \
  allowed_roles="billing,orders,shipping,reports"
```

Then `bao read database/creds/<role>` returns a fresh username and password,
and a `lease_id`.

</details>

<details>
<summary>Hint 2 — what a role says</summary>

A role is SQL with placeholders. `creation_statements` runs when a credential
is issued:

```
bao write database/roles/billing db_name=app \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE app_rw;" \
  default_ttl=1h max_ttl=24h
```

`IN ROLE app_rw` is what lets the new user read `ledger`. Without it you get a
user that can log in and do nothing.

`VALID UNTIL` means Postgres itself refuses the password after the lease
expires, even if OpenBao is down when it should have cleaned up.

</details>

<details>
<summary>Hint 3 — revoking fails with "permission denied for sequence"</summary>

When a role has no `revocation_statements`, OpenBao runs a default. The default
revokes the user's privileges on every table, sequence and schema, one object
at a time, and `bao` does not own those objects. Say exactly what revoking
means here:

```
revocation_statements="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '{{name}}'; DROP ROLE IF EXISTS \"{{name}}\";"
```

The first statement ends the user's open sessions, so a pooled connection
does not outlive its own revocation. The second removes the user.

</details>

<details>
<summary>Solution</summary>

```
bao secrets enable database

bao write database/config/app \
  plugin_name=postgresql-database-plugin \
  connection_url='postgresql://{{username}}:{{password}}@db:5432/app?sslmode=disable' \
  username=bao password=bao-admin-pw \
  allowed_roles="billing,orders,shipping,reports"

for s in billing orders shipping reports; do
  bao write "database/roles/$s" db_name=app \
    creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}' IN ROLE app_rw;" \
    revocation_statements="SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE usename = '{{name}}'; DROP ROLE IF EXISTS \"{{name}}\";" \
    default_ttl=1h max_ttl=24h
done
```

In `.env`, point each service at its role:

```
BILLING_DB_CREDS=database/creds/billing
ORDERS_DB_CREDS=database/creds/orders
SHIPPING_DB_CREDS=database/creds/shipping
REPORTS_DB_CREDS=database/creds/reports
```

```
docker compose up -d
curl localhost:18162/health
```

To cut one service off:

```
bao lease revoke database/creds/orders/<id>        # one credential
bao lease revoke -prefix database/creds/orders     # everything orders holds
```

### What a lease buys you

The shared password could only be "revoked" by changing it everywhere at once.
A leased credential is one user, for one service, for one hour. When `reports`
leaks its connection string, you revoke `reports`'s leases. Within a second
that user does not exist, and the other three never notice.

And the leak you never hear about expires on its own. Nobody remembers to
rotate a password every quarter. A lease ends whether or not anyone
remembers.

### Why one role per service

One role named `app` would also issue distinct, leased users. But the lease
path would be `database/creds/app/…` for all four, so in an incident you could
not tell whose credential to revoke, and `-prefix` would take everyone down.
The path is the name tag.

It also lets the grants differ. `reports` probably needs `SELECT` and nothing
else. With one role per service, that is a change to one line.

### What this lesson leaves out

`svc.py` fetches its credential once and never renews it. When the hour is up,
every service here loses the database. A real service renews its lease while
it runs, or runs `bao agent` next to it to fetch and renew credentials and
rewrite them to a file the app reloads.

Revoking a lease also does not stop the service from asking for another one.
That is what its token is for. In an incident you revoke both: the lease to
end access now, the token to stop it coming back.

`bao` itself has a password that you typed into OpenBao. Run
`bao write -f database/rotate-root/app` and OpenBao changes it to a value only
OpenBao knows.

</details>
