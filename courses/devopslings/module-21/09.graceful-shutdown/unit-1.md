---
title: "A deploy that drops in-flight requests"
---

## The situation

Two replicas of `orders` run behind a load balancer:

```
$ curl -s localhost:18092/order
order placed
$ curl -s 'localhost:18094/stats;csv' | awk -F, '$1=="orders" {print $2, $18}'
a UP
b UP
```

A deploy is a rolling restart. The orchestrator stops `orders-a`, starts it
again, waits for the balancer to put it back in rotation, and then does the same
to `orders-b`. One replica is always up, so in theory nobody notices.

In practice every deploy fails a few dozen requests. Your job is to get that
number to zero.

## What actually happens when a replica is stopped

"Stop" is not one event. It is a short negotiation:

1. The orchestrator sends the process **SIGTERM**.
2. It waits up to the **grace period** (`stop_grace_period`, 10s here). If the
   process is still running at the end, it sends **SIGKILL**, which cannot be
   caught.

Meanwhile the load balancer works on its own schedule. It asks every replica
for `/ready` every 500ms. A replica comes out of rotation after one failed
check and goes back in after two passing ones. It has no idea a deploy is
happening. All it can see is `/ready`.

`orders` ignores all of this. Python's default response to SIGTERM is to die
immediately. Requests it was halfway through are cut off. For up to half a
second afterwards, the balancer still sends new requests to a port nobody is
listening on. This balancer does not retry, and most of the hops between your
users and you don't either, so every one of those requests is a failed request.

## Your objectives

When `orders` gets SIGTERM it should, in this order:

1. Tell the balancer it is leaving.
2. Keep serving until the balancer has stopped sending it traffic.
3. Stop accepting new connections.
4. Finish the requests it has already accepted, then exit, well inside the
   grace period.

## What you're being graded on

During the check, k6 sends steady traffic through the balancer for 45 seconds
while the rolling deploy restarts both replicas:

```js
http_req_failed: ['rate==0'],   // zero failed requests
checks: ['rate==1'],
```

One request in ten is a 5-second export, so there is always slow work in flight
when SIGTERM arrives. The deploy must also finish inside the test window, so a
replica that holds on until SIGKILL fails too.

If requests fail, the check sends SIGTERM to a spare replica, `probe`, and
watches each step. That tells you *which* step is missing.

## How to work on it

The code is `scratch/graceful-shutdown/app.py`, at the root of the repository,
not in the sandbox. It uses only the standard library. The check restarts the
replicas before the deploy, so your current file is always what gets graded.
To try it by hand:

```
docker compose -p devopslings-chaos-stack up -d --force-recreate orders-a orders-b probe
curl -s 'localhost:18093/order?ms=4000' & sleep 0.5
docker compose -p devopslings-chaos-stack kill -s SIGTERM probe
curl -s localhost:18093/ready; wait
docker compose -p devopslings-chaos-stack logs lb    # failed requests, servers going UP/DOWN
```

`STOP_GRACE_PERIOD` in `sandboxes/chaos-stack/.env` sets the grace period.

<details>
<summary>Hint 1 — a longer grace period</summary>

Try it. Set `STOP_GRACE_PERIOD=30s` and run the check: nothing changes. The
starter process dies the moment SIGTERM arrives, so it never uses any of the
grace period. A grace period is a *ceiling* on how long shutdown may take. It
does nothing unless the process uses that time to do something.

</details>

<details>
<summary>Hint 2 — why not just ignore SIGTERM?</summary>

Then the replica keeps serving until the grace period ends, and the balancer
keeps routing to it because `/ready` still says 200. SIGKILL then lands
mid-request. It is the same failure ten seconds later, and every deploy now
takes ten seconds longer per replica.

</details>

<details>
<summary>Hint 3 — the order matters</summary>

Flip readiness first. `ready.clear()` makes `/ready` answer 503. The process
must keep serving after that, because requests the balancer routed before its
next check are still on their way. One check interval plus some slack is
enough. Then `server.shutdown()`.

Do not sleep inside the signal handler itself. Python runs signal handlers on
the main thread, and that thread is the one running `serve_forever()`. Start a
thread instead.

</details>

<details>
<summary>Hint 4 — "finish what you accepted"</summary>

`ThreadingHTTPServer` runs each request on a *daemon* thread. When the main
thread returns, the interpreter exits and daemon threads stop wherever they
are, including halfway through an export. `server_close()` waits for
request threads only if they are not daemons.

</details>

<details>
<summary>Solution</summary>

At the bottom of `scratch/graceful-shutdown/app.py` (and `import signal` at the
top):

```python
DRAIN_DELAY = 1.5


def drain():
    time.sleep(DRAIN_DELAY)  # still serving: requests already routed here land
    server.shutdown()        # then stop accepting


def on_sigterm(signum, frame):
    ready.clear()            # tell the balancer first
    threading.Thread(target=drain).start()


ThreadingHTTPServer.request_queue_size = 128
server = ThreadingHTTPServer(("0.0.0.0", 8080), Handler)
server.daemon_threads = False
signal.signal(signal.SIGTERM, on_sigterm)
print("orders up on :8080", flush=True)
server.serve_forever()
server.server_close()        # joins the in-flight request threads
```

Before:

```
✗ http_req_failed................: 3.37%  45 out of 1333
orders-a stopped after 0s
```

After:

```
✓ http_req_failed................: 0.00%  0 out of 1205
orders-a stopped after 4s
```

"Stopped after 4s" is the improvement. The replica took four seconds to leave
because it was finishing a 5-second export, and nobody noticed.

### The shape of it

```
SIGTERM ─┬─ /ready → 503
         │      ... balancer notices (≤ 0.5s), stops routing
         ├─ +1.5s  stop accepting
         ├─        finish in-flight requests
         └─ exit   (must be < grace period, or SIGKILL finishes it for you)
```

Each step guards against a different failure, and the check's probe looks for
each one:

| Missing | What fails |
|---|---|
| readiness flip | new requests keep arriving until the listener closes |
| delay after the flip | requests routed before the balancer's next check hit a closed port |
| waiting for in-flight | slow requests are cut off at exit |
| handling SIGTERM at all | SIGKILL at the end of the grace period does all of the above at once |

### The same thing, in Kubernetes

The pattern carries over. Kubernetes removes a terminating pod from its Service
endpoints *at the same time* as it sends SIGTERM, not before, and kube-proxy
and ingress controllers learn about the change a moment later. That gap is why
so many deployments have a `preStop: sleep 5` hook. It plays the same part as
`DRAIN_DELAY`: keep serving while the rest of the system catches up. The
default grace period is 30s, and the advice is the same as here: use what you
need and exit.

### What this does not cover

Long-lived connections — WebSockets, gRPC streams, keep-alive clients that hold
a connection open — do not finish on their own. A server has to tell them to go
away: `Connection: close` on the next response, an HTTP/2 GOAWAY, or a
close message on the socket. Then it has to give them a bounded time to leave.
The idea is the same, but in-flight work there includes connections that would
otherwise never end.

</details>
