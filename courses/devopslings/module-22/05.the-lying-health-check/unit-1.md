---
title: "The health check that lies"
---

## The situation

HAProxy asks each app server `GET /health` every second and takes a server
out of rotation when the answer stops being 2xx. That is what made lesson 1
survive a crashed node.

Now web1 is alive but cut off from the back network, where the database is:

```
$ curl -X POST http://www/orders
{"node": "web2", "id": 1003, ...}
error on web1: OperationalError: [Errno -2] Name or service not known
{"node": "web2", "id": 1004, ...}
error on web1: OperationalError: [Errno -2] Name or service not known

$ curl http://web1:8080/health
ok process is up
```

Half of all orders fail, and the load balancer has no idea. The check asks
"is the process running?". The process is running.

`/ha/app/health.py` is what `/health` runs:

```python
def check(db):
    return True, "process is up"
```

`db()` opens a new connection to the app's database. Return `False` (or a
`(False, "reason")` tuple) to answer 503. Saved changes apply to the next
request.

## Your objectives

1. When a node cannot reach its database, it leaves rotation.
2. When it can again, it comes back, without anyone touching it.
3. A healthy node is never taken out.

## What you're being graded on

- Both nodes are `UP` on lb1 and lb2 with everything working.
- The grader cuts web1 off the back network (`node cut web1 back`). Within 10
  seconds web1 must be `DOWN` on both load balancers, and 20 orders in a row
  through `www` must succeed.
- It reconnects web1. Within 20 seconds web1 must be `UP` again.

## Try it yourself

```
node cut web1 back
curl -s 'http://lb1:8404/stats;csv' | cut -d, -f1,2,18
curl -s -w ' %{http_code}\n' http://web1:8080/health
node heal web1 back
```

<details>
<summary>Hint 1 — what does the node need?</summary>

A health check is a question the load balancer asks on behalf of a user:
"if I send you a request now, will it work?" For this app, every page that
matters needs the database. So the check has to touch the database.

</details>

<details>
<summary>Hint 2 — how much to check</summary>

Enough to fail when the node cannot serve, and no more. `SELECT 1` over a new
connection proves the node can reach and log in to its database. Checking
things a request does not need — the replica, another service, free disk on
the database host — takes a working node out for a problem it does not
have. And it must be cheap: two load balancers call it every second on every
node.

</details>

<details>
<summary>Solution</summary>

```python
def check(db):
    try:
        with db() as conn:
            conn.execute("SELECT 1")
    except Exception as e:
        return False, f"database unreachable: {type(e).__name__}"
    return True, "database reachable"
```

### Liveness and readiness

Module 6 drew the distinction for one container: a liveness probe asks
"should this be restarted?", a readiness probe asks "should this get
traffic?". The original check was a liveness answer given to a readiness
question. Restarting web1 would not have helped — nothing was wrong with
it — but sending it traffic was a mistake every time.

### The trap on the other side

Now imagine pg1 itself goes down. Every node's check fails, HAProxy takes
both out, and every request gets a 503 from the load balancer instead of an
error page from the app. A dependency check is right when one node has a
problem the others do not. When the dependency is shared, it takes everyone
out together, and "fail closed" turns into "fail completely". Lesson 9 comes
back to this: sometimes the right answer for a shared dependency is to stay in
rotation and serve something degraded.

</details>
