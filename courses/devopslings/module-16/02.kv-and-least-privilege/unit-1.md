---
title: "One token reads every secret"
---

## The situation

Three services keep their config in OpenBao:

| service    | its secret                | holds                |
|------------|---------------------------|----------------------|
| `billing`  | `secret/billing/config`   | the payment gateway key |
| `orders`   | `secret/orders/config`    | a database password  |
| `shipping` | `secret/shipping/config`  | a carrier API token  |

All three log in with the same token. Its policy, `apps`, was copied from a
tutorial:

```hcl
path "secret/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
```

So shipping can read billing's payment key, and it can overwrite it. A
template-injection bug in shipping's label printer is now a payments incident.
And if the token leaks, revoking it takes all three services down at once.

## Your objectives

1. Give each service a policy that allows reading its own secret, and nothing
   else.
2. Give each service its own token, carrying only that policy.
3. Keep all three services working.

## Getting set up

```
bao() { docker exec -i -e BAO_TOKEN="${BAO_TOKEN:-devopslings-root}" devopslings-ci-stack-bao-1 bao "$@"; }
bao policy read apps
```

The tokens are in `sandboxes/ci-stack/.env`, as `BILLING_BAO_TOKEN`,
`ORDERS_BAO_TOKEN` and `SHIPPING_BAO_TOKEN`. After changing them, recreate the
services from `sandboxes/ci-stack`:

```
docker compose up -d
curl localhost:18165/health   # billing
curl localhost:18166/health   # orders
curl localhost:18167/health   # shipping
```

Each `/health` reads that service's secret from OpenBao with that service's
token.

## What you're being graded on

- Each service runs with its own token. No two share one, and none is a root
  token.
- Each service can still read its own config.
- Each service's token is tried against the other two services' secrets, and
  OpenBao must refuse every one with `permission denied`. These secrets exist,
  so a refusal is the policy at work and not a missing path.
- On its own secret, each token may read and nothing more.

<details>
<summary>Hint 1 — a policy and a token</summary>

A policy is a list of paths and what may be done on each:

```
bao policy write billing - <<'EOF'
path "secret/data/billing/config" {
  capabilities = ["read"]
}
EOF
bao token create -policy=billing -field=token
```

Anything a policy does not grant is denied. There is nothing to deny
explicitly.

</details>

<details>
<summary>Hint 2 — the policy is there, and the read still fails</summary>

`bao kv get secret/billing/config` is a CLI convenience. `secret/` is KV
version 2, and the HTTP API it calls is `secret/data/billing/config`. Version
metadata lives under `secret/metadata/…`. Policies match the API path, so a
policy on `secret/billing/config` matches nothing.

`bao token capabilities <token> <path>` shows what a token may do on a path.
It is the fastest way to test a policy.

</details>

<details>
<summary>Hint 3 — proving it is denied</summary>

Use a service's token to read another service's secret:

```
BAO_TOKEN=<billing's token> bao kv get secret/orders/config
```

You want `Code: 403` and `permission denied`. A `404` would mean the path does
not exist, which proves nothing about the policy. The check reads each secret
with the root token too, so it knows a 403 means "refused" and not "missing".

</details>

<details>
<summary>Solution</summary>

One policy and one token per service:

```
for s in billing orders shipping; do
  printf 'path "secret/data/%s/config" {\n  capabilities = ["read"]\n}\n' "$s" \
    | bao policy write "$s" -
  bao token create -policy="$s" -field=token
done
```

Put each token on its line in `.env`, then:

```
docker compose up -d
```

### What changed

Before, the blast radius of any one service was all three. Now a compromised
shipping can read the carrier token, which it had anyway, and nothing else.
Revoking shipping's token stops shipping and nothing else.

### Why read and nothing more

The services read their config. A deploy pipeline or an operator writes it.
Giving the reader `update` as well means a bug or a stolen token can change the
secret, and a changed secret is harder to notice than a read one. Write access
belongs to whoever is accountable for the value.

### "Proven denied"

Writing a policy and reading it back proves what you *meant*. Trying the wrong
path with the real token proves what OpenBao *does*. They differ more often
than anyone expects: a glob one level too wide, a second policy attached by a
default, a token that was never replaced in the running service. Trying the
read catches all three. Reviewing the policy text catches only the first.

### Tokens in `.env`

These tokens never expire, and they sit in a file. In production a service logs
in with something it already is: a Kubernetes service account, a cloud
instance identity, an AppRole bound to a host. OpenBao then issues it a
short-lived token with these same policies. The policies do not change. Only
where the token comes from does.

</details>
