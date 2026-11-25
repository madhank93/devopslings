---
title: "The payment provider knows which tenant every order is for"
---

## The situation

checkout serves three tenants — acme, globex, initech — and the finance team
wants every span tagged with the tenant it was for, in every service. Passing
a `tenant_id` argument through every function and every API was not going to
happen, so checkout puts it in **baggage** once, when the order comes in, and
ledger reads it back out of the request it receives:

```python
ctx = baggage.set_baggage("tenant.id", tenant, context=propagate.extract(incoming))
```

It works: ledger's spans carry `tenant.id`. Then a security review read the
payment provider's request logs, which the provider shares with you:

```
curl -s http://billing:8080/v1/_seen | jq '.[-1].headers'
```

The provider is another company. `billing:8080` is the lab's stand-in for its
API; `/v1/_seen` shows what its logs hold.

The source is `/obs/apps/checkout.py` and `/obs/apps/ledger.py`. Saving a
file restarts that service, and its output is in `/obs/logs/<name>.log`.

## Baggage goes where the context goes

Baggage is key-value pairs carried in the context next to the span, and sent
in its own header:

```
traceparent: 00-4bf92f3577b34da6a3ce929d0e0e4736-00f067aa0ba902b7-01
baggage: tenant.id=acme
```

The default propagator is a composite of W3C Trace Context and W3C Baggage,
so `propagate.inject(headers)` writes both headers from whatever context is
current. It has no idea whether the URL is ledger or another company. Every
outgoing call that injects the context sends the baggage with it.

The W3C Baggage specification says this in its privacy section: baggage is
propagated to every downstream service, including ones outside your control,
so it must not hold anything you would not hand to them. A tenant id tells the
provider who your customers are; a user id or an email in baggage is worse.

Spans themselves never carry baggage. A value in baggage reaches a span only
when some code copies it there, as ledger does with `baggage.get_baggage`.

## Your objectives

Keep `tenant.id` on checkout's `POST /checkout` span and on every span ledger
makes, and keep it out of every request that reaches the payment provider.
Every order still gets charged. Don't edit `billing.py`: you do not control
what another company receives, only what you send it.

## What you're being graded on

The check places its own orders with a fresh tenant name and:

- the provider is asked to charge each of them, and no header it receives has
  a `baggage` header, a header naming the tenant, or the tenant's value
- checkout's `POST /checkout` span and every ledger span in those orders'
  traces have `tenant.id` set to that tenant

<details>
<summary>Hint 1 — why turning baggage off is not the fix</summary>

Set the propagators to Trace Context alone (`OTEL_PROPAGATORS=tracecontext`
or `propagate.set_global_textmap(TraceContextTextMapPropagator())`), and the
provider stops seeing the tenant. So does ledger: its spans come back with an
empty `tenant.id`. The fix is per call, not global.

</details>

<details>
<summary>Hint 2 — inject from a different context</summary>

`propagate.inject(carrier, context=...)` injects from the context you give it
instead of the current one. `opentelemetry.baggage` has a function that
returns the current context with every baggage entry removed and the span
left as it was.

</details>

<details>
<summary>Solution</summary>

In `/obs/apps/checkout.py`, let `call` take a context, and give the
provider's call one with no baggage:

```python
def call(url, payload, ctx=None):
    headers = {"Content-Type": "application/json"}
    propagate.inject(headers, context=ctx)
    ...

call(PROVIDER, {"reference": order["order_id"], "amount": order["amount"]}, baggage.clear())
```

`baggage.clear()` keeps the current span, so the provider still gets a
`traceparent` it can quote back to you in a support ticket. ledger, called
with the current context, still gets the tenant.

In a larger codebase the same rule usually lives in one place: the HTTP
client wrapper for external calls, or an egress proxy that strips `baggage`
at the boundary. Either way the decision is "what may leave", made where
requests leave.

### The ways this goes wrong

- **Stop using baggage.** The provider is clean and ledger's spans lose the
  tenant, which was the reason baggage was there.
- **Trace Context as the only global propagator.** Same result: nothing
  injects baggage anywhere, internal calls included.
- **Hashing or renaming the key.** `tenant.id` → `t` or a hash of the tenant
  is still a stable per-tenant identifier in another company's logs.
- **Removing the header in the provider's code.** That is the other
  company's service; the check rejects a changed `billing.py`.

</details>
