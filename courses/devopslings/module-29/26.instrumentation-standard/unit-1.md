---
title: "Every team instruments differently"
---

## The situation

Three services, one trace from each, in `/obs/standard/samples/` as
OTLP/JSON, the format the Collector's file exporter writes:

```
jq '.resourceSpans[].resource.attributes, .resourceSpans[].scopeSpans[].spans[] | {name, kind, attributes}' \
  /obs/standard/samples/checkout.json
```

checkout sends `httpStatus` and the raw URL with the cart ID in it.
payments calls itself `payments-svc`, names every span `handle`, and has no
environment. search is close to right and has no version. A dashboard that
groups latency by route works for one service in three, and nobody can
tell whether a bad deploy is the cause of anything, because two services
do not say which version they are running.

`/obs/standard/TEAMS.md` says who owns what. Every service imports
`obs-lib`, a shared package that sets up OpenTelemetry, and every merge
request runs through one CI pipeline.

## What makes a standard hold

A standard is three things, and teams treat it as optional if any one is
missing:

1. **Names.** Which attributes are required, spelled as the OpenTelemetry
   **semantic conventions** spell them, and which release of the
   conventions. Names have moved between releases:
   `http.method` became `http.request.method`, `http.status_code` became
   `http.response.status_code`, `deployment.environment` became
   `deployment.environment.name`.
2. **An owner.** Shared instrumentation, such as the setup library and HTTP
   middleware, is what most services actually get their attributes from.
   One team owns it, so a fix lands once for everyone.
3. **A gate.** Something that fails a change which does not meet it, in
   the review path, with a message that says what to add. A document
   nobody checks is a suggestion.

Some attributes belong on every span's **resource** (who sent it), and some
only on certain spans: an HTTP route is a property of the server handling a
request, not of a client calling out.

In OTLP/JSON, a span's `kind` is a number: `2` is SERVER, `3` is CLIENT.

## Your objectives

1. `/obs/standard/standard.yaml`: the semantic-conventions release, the
   required resource attributes, the required SERVER span attributes, and
   the owner of shared instrumentation.
2. `/obs/standard/gate`: given one OTLP/JSON export, exit 0 when it meets
   the standard; otherwise print each missing attribute and exit non-zero.
   It reads `standard.yaml` rather than repeating it. Python and PyYAML are
   in the box.

## What you're being graded on

- the standard names a semconv release; requires `service.name`,
  `service.version` and `deployment.environment.name` on the resource, and
  `http.request.method`, `http.route` and `http.response.status_code` on
  SERVER spans; and none of the ad-hoc names
- the owner is one team, and the right one
- the gate, run on the check's own exports: passes a compliant service and
  one that only has CLIENT spans; fails, naming the missing attribute, a
  service with no version, no environment, ad-hoc HTTP names, or one SERVER
  span of two without a route
- with an attribute added to `standard.yaml`, the gate fails a service
  without it

<details>
<summary>Hint 1 — reading an export</summary>

`resourceSpans[].resource.attributes` is a list of `{"key": ..., "value":
{...}}`. Spans are under `resourceSpans[].scopeSpans[].spans[]`, each with
its own `attributes` and `kind`. A set of keys per resource and per span is
all the gate needs.

</details>

<details>
<summary>Hint 2 — the owner</summary>

Who maintains the code that sets the attributes for every service?

</details>

<details>
<summary>Solution</summary>

```yaml
semconv_version: "1.30.0"
resource_attributes: [service.name, service.version, deployment.environment.name]
server_span_attributes: [http.request.method, http.route, http.response.status_code]
shared_instrumentation_owner: platform
```

`gate`, in Python:

```python
#!/usr/bin/env python3
import json, sys
import yaml

std = yaml.safe_load(open("/obs/standard/standard.yaml"))
keys = lambda attrs: {a["key"] for a in attrs or []}
missing = set()
for rs in json.load(open(sys.argv[1])).get("resourceSpans", []):
    have = keys(rs.get("resource", {}).get("attributes"))
    missing |= {f"resource: {k}" for k in std["resource_attributes"] if k not in have}
    for ss in rs.get("scopeSpans", []):
        for s in ss.get("spans", []):
            if s.get("kind") in (2, "SPAN_KIND_SERVER"):
                have = keys(s.get("attributes"))
                missing |= {f"SERVER span '{s['name']}': {k}" for k in std["server_span_attributes"] if k not in have}
if missing:
    print("missing:\n" + "\n".join(sorted(missing)))
    sys.exit(1)
```

In the real pipeline, each service's CI runs its integration tests with the
Collector's file exporter on, and runs the gate on what it wrote. platform
puts the required attributes into `obs-lib`'s defaults, so most services
pass by upgrading it.

### The ways this goes wrong

- **Writing down what services already send.** `httpStatus` and `env` in
  the standard make today's mess permanent.
- **"Every team owns its instrumentation."** That is how three services
  ended up with three spellings.
- **A gate with the list hard-coded.** It agrees with the standard until
  someone edits one of them.
- **Requiring the route on every span.** A CLIENT span calling another
  service has no route of its own, and a gate that demands one fails every
  service that makes outgoing calls, until someone switches it off.
- **Failing without saying what is missing.** The author of the blocked
  change has to go and read the standard to find out, and starts looking
  for a way around the gate.

</details>
