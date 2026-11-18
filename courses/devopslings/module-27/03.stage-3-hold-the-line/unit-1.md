---
title: "Hold the line: the SLO through a release and a failure"
---

## The situation

checkout is in production. If your stage 1 passes, it is your pipeline. If it
does not, the scenario lays the reference down first. It now has an SLO,
committed beside the code in `slo.yaml`:

```yaml
availability_percent: 99.9   # requests through www answered without an error
latency_p99_ms: 500          # 99 in 100 requests answered within this
```

An SLO that holds only on quiet days is not much of a promise. The check
runs an experiment:

1. Customers arrive at a constant 40 requests a second for two and a half
   minutes, from k6 on ha-stack's `front` network. Arrivals do not slow down
   when `www` does, so every second of trouble is counted.
2. Ten seconds in, the grader pushes a release: a new `VERSION`, through your
   pipeline, to production.
3. Once the release is live, the grader stops one replica the way a drained
   host would: SIGTERM, then SIGKILL ten seconds later. When the replica has
   gone, the grader starts it again.

Errors are counted twice: by the load balancers, and by k6. obs-stack's
Prometheus is connected to `front` and scrapes HAProxy's own exporter on lb1
and lb2 (`:8404/metrics`):

```console
$ open 'http://localhost:19090/graph?g0.expr=sum(increase(haproxy_frontend_http_responses_total{proxy="www"}[5m]))%20by%20(code)'
```

A request HAProxy never answers is not in those counters: one waiting on a
replica that has vanished times out at the customer first. k6 counts it, and
the grader takes whichever count is higher.

As shipped, a release replaces both replicas at once, and customers wait on
HAProxy's retries while it happens; p99 goes to a second. A replica told to
stop ignores SIGTERM until it is killed, and requests fail until the
balancers notice it has gone: about four times the error budget.

## Your objectives

1. Make a release invisible to customers: never take away the capacity that
   is serving them.
2. Make a replica that is told to stop leave rotation before it stops
   answering.
3. Leave `slo.yaml` alone. A bigger error budget is a different promise, not a
   fix.

## What you're being graded on

During the experiment, no more errors than 0.1% of the requests k6 made (the
load balancers' 5xx count from Prometheus, or k6's own count of failures if
that is higher), and a p99 within 500ms. The release has to reach `www`. The
replica the grader stops has to answer `/health` with something other than
200 while `/` still answers 200, before it goes. Then all of stage 1 runs
again.

Every experiment is recorded in the capstone's event log, which stage 4 reads.
The last one's numbers are in `scratch/stage-3-hold-the-line/last-experiment`.

<details>
<summary>Hint 1: what a deploy does to the replicas</summary>

Watch a plan: changing the image forces the replacement of every
`docker_container` that uses it. OpenTofu replaces them in parallel, and
the docker provider removes a container outright unless
`destroy_grace_seconds` is set. Both replicas are gone at the same moment.
HAProxy keeps sending them traffic until two health checks a second apart
have failed.

`-target` lets a job apply one resource at a time. A job running the ops
image has the docker CLI and the host's socket, so it can ask the balancers
for their view (`docker exec devopslings-ha-ops curl -s 'http://lb1:8404/stats;csv'`)
before it moves on to the next replica.

</details>

<details>
<summary>Hint 2: what a stopping replica owes the balancers</summary>

Module 21's graceful shutdown applies here. The process runs as PID 1 in its
container, and PID 1 ignores SIGTERM unless it installs a handler. Without
one, `docker stop` waits out its grace period and then SIGKILLs it.

The handler should fail `/health` first, keep serving while the checks catch
up (`inter 1s fall 2`), and only then close.

Raising HAProxy's timeouts or retries does not help. A request that waits
four seconds for a dead replica is not an error, but it is still a broken
promise, and p99 counts it.

</details>

<details>
<summary>Solution</summary>

`src/server.js` drains on SIGTERM:

```js
let draining = false;
const server = http.createServer((req, res) => {
  if (req.url === "/health") {
    res.statusCode = draining ? 503 : 200;
    res.end(JSON.stringify({ ok: !draining }));
    return;
  }
  // ... as before
});
server.listen(8080);

process.on("SIGTERM", () => {
  draining = true;
  setTimeout(() => {
    server.close(() => process.exit(0));
    server.closeIdleConnections();
    setTimeout(() => process.exit(0), 2000).unref();
  }, 4000);
});
```

`deploy/main.tf` stops containers with a grace period instead of removing
them:

```hcl
resource "docker_container" "shop" {
  count                 = 2
  name                  = "capstone-shop-${count.index + 1}"
  image                 = docker_image.shop.image_id
  destroy_grace_seconds = 10
  # ...
}
```

And the deploy job rolls:

```sh
for i in 0 1; do
  tofu apply -input=false -auto-approve -target="docker_container.shop[$i]" \
    -var "image=${IMAGE}@${digest}"
  for _ in $(seq 60); do
    up=$(docker exec devopslings-ha-ops sh -c \
           "curl -fsS 'http://lb1:8404/stats;csv'; curl -fsS 'http://lb2:8404/stats;csv'" \
         | awk -F, -v s="shop$((i + 1))" '$1 == "app" && $2 == s && $18 == "UP"' | wc -l || true)
    [ "$up" -eq 2 ] && break
    sleep 1
  done
done
tofu apply -input=false -auto-approve -var "image=${IMAGE}@${digest}"
```

### The part worth remembering

**Rolling and draining need each other.** A rolling deploy without a drain
still drops every request in flight on each replica it replaces. A drain
without rolling takes both replicas out at once, gracefully. Neither alone
holds the SLO.

**Measure where the customer is.** The error budget comes from the load
balancers' own counters and the latency from the client. A dashboard of the
replicas' own health would have shown green throughout.

</details>
