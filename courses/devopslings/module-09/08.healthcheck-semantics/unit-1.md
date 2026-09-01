---
title: "the container is unhealthy and it is serving traffic fine"
---

## The situation

The price API is up. It answers every request you throw at it. Docker says it is
unhealthy, and the deploy that waits for healthy never finishes:

```
$ docker compose -p devopslings-healthcheck up -d --build
$ curl -s localhost:18082/
api v2

$ docker compose -p devopslings-healthcheck ps
NAME                             STATUS
devopslings-healthcheck-api-1    Up 32 seconds (unhealthy)
```

Two facts that both need explaining: the service works, and the platform is
certain it does not. Somebody has already suggested deleting the `HEALTHCHECK`
line, which would make the deploy go green and is the reason this lesson exists.

There is a second thing wrong that the first hides. The app takes ten seconds to
load its price cache, and answers `503` on `/price` until it has. Whatever the
check ends up asking, it has to be false during those ten seconds — otherwise
the deploy declares the service ready while it is still returning errors.

## Your objectives

1. Make the health check tell the truth: false while the cache is loading, true
   once the app can answer a price.
2. Make `docker compose up -d --wait` return 0 — blocking until the service can
   actually serve, and not failing on the way there.

`app.py` is the scenario, not the bug. The ten-second warm-up is what a real
service does; do not remove it.

## What you're being graded on

The grader runs your health check command itself, inside the container: once
three seconds in, where it must fail, and again once `/ready` is answering 200,
where it must pass. Then it brings the stack up with `--wait` and requires that
to return 0, having blocked for the warm-up, with `/price` serving afterwards.

<details>
<summary>Hint 1 — run the check by hand</summary>

A health check is a command Docker runs *inside the container*, and its exit
status is the whole answer. So run it yourself:

```
docker compose -p devopslings-healthcheck exec api sh -c 'curl -f http://localhost:8080/'
```

Read the error carefully. It is not about the app.

</details>

<details>
<summary>Hint 2 — what the image actually contains</summary>

`python:3.12-slim` is Python and not much else. `curl` is not in it, and a
missing command exits 127, which is a failure like any other — Docker cannot
tell "the service is broken" from "the command does not exist".

You can install curl, or you can use what is already there:

```
python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:8080/…').read()"
```

`urlopen` raises on a 4xx or 5xx, and an uncaught exception exits non-zero,
which is exactly the semantics a health check wants.

</details>

<details>
<summary>Hint 3 — which URL, and when it is allowed to fail</summary>

`/` answers 200 from the moment the process is listening. `/ready` answers 503
until the cache is warm. Only one of those is a readiness check.

Then fix the second problem the first one was hiding: with
`--interval=2s --retries=3`, three failures take six seconds and the warm-up
takes ten, so a correct check marks the container unhealthy before the app has
finished starting — and `up --wait` fails there. Look up `--start-period`.

</details>

<details>
<summary>Solution</summary>

```dockerfile
HEALTHCHECK --interval=2s --timeout=3s --retries=3 --start-period=30s \
  CMD ["python3", "-c", "import urllib.request; urllib.request.urlopen('http://localhost:8080/ready').read()"]
```

```
$ time docker compose -p devopslings-healthcheck up -d --wait
 Container devopslings-healthcheck-api-1  Healthy
docker compose up -d --wait  11.2s

$ curl -s localhost:18082/price
eur:1.0842
```

Three changes, each fixing a different thing:

- **`/ready` instead of `/`** — the check now asks a question whose answer is
  false while the service cannot work.
- **`python3` instead of `curl`** — the check runs inside the container, where
  the image's contents are all it has.
- **`--start-period=30s`** — failures during the first thirty seconds do not
  count toward the retries, so a legitimately slow start is not a failure.

### The part worth remembering

A health check answers one question — *should traffic go here?* — and everything
about it follows from that:

- **It runs inside the container.** Its dependencies are the image's
  dependencies. A check written against tools that are not in the image fails
  identically to a check against a dead service, and 127 looks exactly like a
  real failure. This is the single most common broken health check in the wild.
- **It must depend on the thing that can be broken.** A check that hits a static
  route tests that the process is listening — which the platform already knows,
  because the process is running. The useful check exercises the path that fails:
  the cache being loaded, the database connection being live, the migration
  having finished.
- **But not on things you do not control.** A check that calls a downstream
  service turns one outage into two, because every instance goes unhealthy
  together and the orchestrator removes them all. Check your own readiness,
  not the world's.

`--start-period` exists because starting is not the same as failing. Inside it,
a failing check does not count toward `--retries`; it is the difference between
"slow to boot" and "broken", and without it any app that takes longer to warm up
than `interval × retries` can never come up at all.

The vocabulary is worth carrying to Kubernetes, where the three questions are
split into three probes: **liveness** (is it wedged — restart it), **readiness**
(should it get traffic — remove it from the load balancer), and **startup** (is
it still booting — hold the other two off), which is `--start-period` with a
name. Docker's one `HEALTHCHECK` has to serve all three roles, so the readiness
question is the one to write it around.

And the reason not to delete it: `docker compose up --wait`, a rolling deploy,
and a load balancer's backend set all read that one bit. Deleting the check does
not make the service healthy — it makes the platform stop asking, and shifts the
detection of a bad deploy from your pipeline to your users.

</details>
