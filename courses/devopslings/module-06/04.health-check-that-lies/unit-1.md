---
title: "the load balancer says both nodes are healthy and half the requests fail"
---

## The situation

```
$ for i in $(seq 1 6); do curl -s -o /dev/null -w '%{http_code} ' http://127.0.0.1:8000/orders; done
200 503 200 503 200 503
```

Alternating. Two backends, round-robin, and one of them fails every request it
is given. The load balancer has not noticed:

```
$ echo "show stat" | socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18
app,a,UP
app,b,UP
```

2/2 healthy, on every dashboard, for as long as this has been happening. The
check is running, it is passing, and it is telling the truth about the question
it was asked.

## What the check actually asked

```
option httpchk GET /health
```

And what `/health` does on that backend:

```
$ curl -s -o /dev/null -w '%{http_code}\n' http://172.32.0.11:8090/health
200
$ curl -s -o /dev/null -w '%{http_code}\n' http://172.32.0.11:8090/orders
503
```

The endpoint answers 200 while the node cannot serve a single real request. It
is not lying about anything it was asked — it was asked *are you running*, and
it is running. Nobody asked whether it could do its job.

This is the distinction that matters, and it has names:

**Liveness** — is this process alive? Should it be restarted? A liveness check
that fails means "kill this and start a new one". It must not depend on
anything external, because a database outage should not cause every application
node to be restarted in a loop.

**Readiness** — can this instance serve a request right now? Should it get
traffic? A readiness check *must* depend on the things a request depends on: the
database connection, the cache, the credential that expired, the config it
failed to load.

A load balancer wants readiness. Restarting is not its business; deciding who
gets traffic is. Pointing it at a liveness endpoint produces exactly the failure
in this lesson — the pool stays "healthy" while the requests fail — and it is
easy to do, because `/health` is what everyone's application ships with and its
name suggests it means more than it does.

```
$ curl -s -o /dev/null -w '%{http_code}\n' http://172.32.0.11:8090/ready
503
```

That endpoint was there all along.

## Why the interval is not the fix, and is still part of it

The instinct on seeing a load balancer miss a bad node is to check more often.
Here that changes nothing: a check that asks the wrong question gives the wrong
answer at any frequency. Ten times a second, the sick node passes.

But once the check is *right*, the frequency decides how long the outage lasts.
HAProxy ejects a server after `fall` consecutive failed checks and restores it
after `rise` consecutive successes, both counted in `inter` intervals:

```
default-server check inter 10s fall 3 rise 2
```

That is a correct check that takes **thirty seconds** to act. Thirty seconds of
sending traffic to a node that cannot serve it, every time one goes sick. And
`rise 2` means twenty seconds before a recovered node is used again.

The two dials pull against each other, and neither extreme is right:

- **Too slow** — long outages on every failure, and slow recovery afterwards.
- **Too fast** — a node is ejected for one slow moment, the traffic it was
  handling lands on its neighbours, they get slower, and they get ejected too.
  That is how a health check turns a blip into a cascade.

`inter 2s fall 2 rise 2` — out in four seconds, back in four — is a reasonable
place to be for a check this cheap. The right answer depends on how expensive
the check is and how bursty the service is; the wrong answer is leaving it at
whatever the example config had.

## Your objective

1. A node whose dependency has just broken is out of rotation **within 15
   seconds**. A node whose dependency is healthy is in rotation and is **not**
   ejected while it is healthy. Both are tested by breaking and repairing a
   backend while you are graded.

2. Write `/root/answers/healthcheck.md`:

   ```
   check_path: <path the load balancer now asks for>
   health_proves: <liveness | readiness>
   ```

The load balancer config is yours. The backends are not: you cannot change what
they serve, and the dependency is not coming back on your schedule.

## What you're being graded on

**Both healthy nodes serve.** Twelve requests have to come back clean and touch
both backends. A check nothing can pass — or a backend quietly deleted from the
pool — takes the outage from half the traffic to all of it on the day the
*other* node is the sick one.

**A sick node leaves inside the deadline.** The grader breaks backend b and
watches; `inter` × `fall` has to fit in fifteen seconds.

**A recovered node comes back.** Ejection is not a one-way door. `rise`
intervals later it should be taking traffic again.

**The path you name is a path that knows.** Whatever you put in `check_path` is
requested against a backend with the dependency broken and again with it
healthy. It has to answer differently. That check accepts any endpoint that
genuinely reflects the dependency — `/ready` is the one that exists here, but a
real work route would pass too.

<details>
<summary>Hint 1 — ask the sick backend three questions</summary>

```
$ curl -s -o /dev/null -w '%{http_code}\n' http://172.32.0.11:8090/health
$ curl -s -o /dev/null -w '%{http_code}\n' http://172.32.0.11:8090/ready
$ curl -s -o /dev/null -w '%{http_code}\n' http://172.32.0.11:8090/orders
```

Two of those three agree with each other and disagree with the one the load
balancer is asking.

</details>

<details>
<summary>Hint 2 — watch the pool while you change things</summary>

```
$ watch -n1 'echo "show stat" | socat stdio /run/haproxy/admin.sock | cut -d, -f1,2,18,19'
```

Column 18 is status, 19 is the check result. Break the dependency with

```
$ curl -s -X POST 'http://172.32.0.11:8091/admin/deps?value=broken'
```

and see whether anything moves — and how long it takes.

</details>

<details>
<summary>Hint 3 — both dials</summary>

`option httpchk GET <path>` chooses the question. `inter`, `fall` and `rise` on
the `default-server` line choose how quickly the answer is acted on: out after
`fall` failures, back after `rise` successes, one per `inter`.

Fifteen seconds is the deadline. `inter 10s fall 3` is thirty.

</details>

## What actually happened

Backend b lost its dependency. Its process stayed up, so `GET /health` kept
returning 200, so the check kept passing, so HAProxy kept giving it a third of
a second's worth of traffic — all of which it answered 503.

Nothing was broken about HAProxy, and nothing was broken about the check
mechanism. The check was pointed at an endpoint that could not observe the
failure. The endpoint that could was sitting next to it, unused.

The repair is two lines:

```nginx
option httpchk GET /ready
default-server check inter 2s fall 2 rise 2
```

The first makes the answer correct. The second makes it timely.

<details>
<summary>Solution</summary>

```
defaults
    mode http
    timeout connect 3s
    timeout client 15s
    timeout server 15s

    option httpchk GET /ready
    default-server check inter 2s fall 2 rise 2

frontend gateway
    bind *:8000
    default_backend app

backend app
    server a 172.32.0.11:8080
    server b 172.32.0.11:8090
```

```bash
$ haproxy -c -f /etc/haproxy/haproxy.cfg && systemctl reload haproxy
$ printf 'check_path: /ready\nhealth_proves: liveness\n' > /root/answers/healthcheck.md
```

</details>

## Carrying this forward

- **Liveness answers "restart me"; readiness answers "give me traffic".** They
  are different questions with different dependencies, and a load balancer wants
  the second one.
- **A readiness endpoint must touch what a request touches.** If it can return
  200 without consulting the database the request needs, it will — on the day
  the database is down.
- **But do not make liveness deep.** A liveness probe that fails when the
  database is down restarts every node in the fleet during a database outage,
  which is how a bad hour becomes a bad day.
- **"Healthy" on a dashboard is a claim about a check, not about a service.**
  When the graph disagrees with the error rate, the graph is measuring the wrong
  thing — the error rate is never wrong.
- **`inter` × `fall` is the length of the outage.** Correctness decides whether
  the node is ever removed; the interval decides how many requests fail first.
