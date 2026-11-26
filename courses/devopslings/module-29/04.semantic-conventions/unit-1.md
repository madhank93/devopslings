---
title: "checkout's spans say url and httpStatus, and nobody can group latency by route"
---

## The situation

checkout is the order API: `GET /orders/<id>`, `GET /customers/<id>/orders`
and `POST /orders`. It traces every request by hand and sends the spans
through the Collector to Tempo. Someone asked a simple question, "which
endpoint is slow?", and nobody could answer it.

```
curl -s checkout:8080/orders/1042
curl -s 'http://tempo:3200/api/search/tags?scope=span' | jq
```

The spans carry `method`, `url` and `httpStatus`. Grafana's trace views,
Tempo's metrics generator, the Collector's spanmetrics connector and every
APM product look for different names, find nothing, and group nothing.

The team's first guess is to rename the fields in a dashboard. That fixes
one panel. Every other tool reading the spans still sees `url`, and `url` is
`/orders/1042`, `/orders/1043`, `/orders/1044`: one value per order, which
would not group even under the right name.

The source is `/obs/apps/checkout.py`. Saving it restarts checkout; its
output is in `/obs/logs/checkout.log`. The Collector's config is
`/obs/otel/collector.yaml`.

## Semantic conventions

OpenTelemetry's **semantic conventions** fix the names, types and meanings
of common attributes, so a span written by one team means the same thing to
every tool. The stable HTTP server conventions include:

| Attribute | Type | Example |
|---|---|---|
| `http.request.method` | string | `GET` |
| `url.path` | string | `/orders/1042` |
| `http.route` | string | `/orders/{id}` |
| `http.response.status_code` | int | `404` |

`http.route` is the one that groups. It is the **template** the request
matched, with the variable parts left as placeholders, so every order lands
in the same group. Only the server knows it: the router matched the path
against it a moment ago. The conventions also name the span
`{method} {route}`, such as `GET /orders/{id}`.

Before version 1.21 of the conventions the status code was
`http.status_code`. Older instrumentation still emits it; current tools read
`http.response.status_code`.

You can set the attributes where the span is made, in the SDK. Or the
Collector can rewrite them on the way through, with the **transform**
processor and OTTL statements such as `set(attributes["x"], attributes["y"])`
and `delete_key(attributes, "y")`. The SDK knows the route; the Collector
has to rebuild it from the path with a pattern.

## Your objectives

Make checkout's spans carry, on every request:

- `http.response.status_code`, as an integer, equal to the status checkout
  answered
- `http.route`, the route template the request matched

Keep checkout's responses as they are.

## What you're being graded on

The check sends 30 requests across the three endpoints, with order and
customer ids it makes up, each with a `traceparent` of its own, then reads those traces from Tempo:

- every request's span is there, from service `checkout`
- each span's `http.response.status_code` is an integer equal to the status
  checkout answered that request
- every span has `http.route`, and over the 30 requests it has exactly
  three values, none containing an id the check sent

<details>
<summary>Hint 1 — the status code</summary>

`httpStatus` is set with `str(status)`. A TraceQL comparison such as
`span.http.response.status_code >= 500` only matches an integer.

</details>

<details>
<summary>Hint 2 — the route</summary>

`ROUTES` already holds a regex per endpoint. Give each one its template as
well, and set `http.route` from the entry that matched.

</details>

<details>
<summary>Solution</summary>

Give each route its template:

```python
ROUTES = [
    ("GET", r"/orders/(\d+)", get_order, "/orders/{id}"),
    ("GET", r"/customers/(\d+)/orders", customer_orders, "/customers/{id}/orders"),
    ("POST", r"/orders", place_order, "/orders"),
]
```

And set the conventional attributes in the handler:

```python
span.set_attribute("http.request.method", self.command)
span.set_attribute("url.path", self.path)
...
for method, pattern, fn, route in ROUTES:
    m = re.fullmatch(pattern, self.path)
    if m and method == self.command:
        span.set_attribute("http.route", route)
        span.update_name(f"{method} {route}")
        ...
span.set_attribute("http.response.status_code", status)
```

The Collector route works too: a `transform` processor in the traces
pipeline that sets `http.response.status_code` to `Int(attributes["httpStatus"])`
and builds `http.route` from `url` with `replace_pattern`. It keeps a second
copy of the router in YAML, which drifts the day someone adds an endpoint.

### The ways this goes wrong

- **Renaming in the dashboard.** The spans are unchanged; the check reads
  them, as every other tool does.
- **`http.route` set to the path.** Right name, one value per order. The
  check names one of the values it found.
- **The status as a string.** `str(status)`, or OTTL's `set` without
  `Int()`, gives `"404"`, which no numeric query matches.
- **`http.status_code`.** The pre-1.21 name. The check says so.

</details>
