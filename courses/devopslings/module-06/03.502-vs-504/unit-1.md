---
title: "two routes, two 5xx, and the same three restarts will not fix either"
---

## The situation

```
$ curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://127.0.0.1/orders
502 0.002s
$ curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://127.0.0.1/users
504 3.004s
```

A dashboard counting 5xx shows one number for these two. They have nothing in
common except the proxy that reported them, and the fix for one is at the
opposite end of the wire from the fix for the other.

nginx has been restarted twice. Of course it has — it is the thing whose name is
on the error. It is also the only component in this picture that is working
correctly.

Read the two numbers on the right before anything else. One failed in two
milliseconds; one failed in three seconds and change. That difference is the
diagnosis, and it is visible before you open a single log.

## What each code actually claims

**502 Bad Gateway** — *I could not get a response out of the upstream at all.*
The proxy tried, and either nothing was listening, or something was listening
and did not answer. It is a statement about the far end. It comes back fast,
because failing to get a connection or having one closed under you takes no
time at all.

**504 Gateway Timeout** — *I gave up waiting.* The connection was fine. The
upstream took it, is presumably still working on it, and the proxy stopped
waiting after a deadline that the proxy itself chose. It is a statement about
a deadline — one that lives in your configuration.

That is the asymmetry worth carrying: **a 502 is about them; a 504 is about
your patience with them.** Which is why a 504 can be "fixed" by a setting on the
proxy and a 502 cannot.

## The error log says which, in one line

nginx writes exactly one line per failed upstream attempt, and the three you
will meet are distinguishable at a glance:

```
$ tail -3 /var/log/nginx/error.log
... upstream prematurely closed connection while reading response header from upstream
... upstream timed out (110: Connection timed out) while reading response header from upstream
... connect() failed (111: Connection refused) while connecting to upstream
```

| Log line | Status | What happened |
|---|---|---|
| `connect() failed (111: Connection refused)` | 502 | Nothing was listening on that port. The process is gone, or the port is wrong. |
| `upstream prematurely closed connection` | 502 | Something accepted the connection and hung up without writing a response. A crashed worker, an upstream that segfaulted mid-request, a container being killed. |
| `upstream timed out (110)` | 504 | The connection was fine and the response did not arrive inside `proxy_read_timeout`. |

Note that the first two are both 502 and are *not* the same problem. "Refused"
means the process is not there. "Prematurely closed" means it is there and it
died on you — which is worse, because it will happen again and a health check
that only opens a socket will not notice.

## The 504 is a negotiation, not a fault

Here is the part that gets skipped. In this scenario the users report takes six
seconds because it takes six seconds — it is a report, it does work. Nothing
about the upstream is broken. The proxy was told to wait three:

```nginx
proxy_read_timeout 3s;
```

Both numbers are defensible. They are simply inconsistent, and nobody compared
them. The repair is to make the deadline longer than the work on the route
where the work is genuinely that long.

The trap is doing it in the wrong place:

```nginx
server {
    proxy_read_timeout 20s;      # everything on this server now waits 20s
    location /orders { ... }
    location /users  { ... }
}
```

That fixes `/users` and quietly signs `/orders` up for it too. The next time the
orders backend stalls, every request to it holds a worker for twenty seconds
instead of three. Workers are finite; when they are all parked against a stalled
dependency, the site is down — not one route, all of it. One slow dependency
becoming a full outage is the standard shape of these incidents.

So the deadline goes where the work is:

```nginx
location /users {
    proxy_pass http://172.32.0.11:8080;
    proxy_read_timeout 15s;
}
```

And this is why "make the backend faster" is not the answer here either. It
would make the symptom stop today, and the report is still a six-second report.
This exercise puts the six seconds back before grading, for exactly that reason.

## Your objective

1. `http://127.0.0.1/orders` returns `orders: 1001 1002`.
2. `http://127.0.0.1/users` returns `users: alice bob carol`. The users backend
   takes six seconds, will keep taking six seconds, and is set back to six
   seconds before you are graded.
3. Write `/root/answers/gateway.md`, exactly three lines:

   ```
   orders_cause: <closed | refused | timeout>
   users_cause:  <closed | refused | timeout>
   users_upstream_seconds: <number>
   ```

   The last one is measured against the backend directly, not through the proxy.

The backends are two separate processes, each with an admin API:

```
orders  ->  172.32.0.11:8090   admin 8091
users   ->  172.32.0.11:8080   admin 8081
```

## What you're being graded on

**Both routes return their bodies**, and `/orders` is answered by the orders
backend — the response carries `X-Upstream: b`. Pointing the route at the other
backend, or answering it with `return 200` from nginx, hides the outage instead
of ending it.

**`/users` took its six seconds.** A body that arrives instantly did not come
from that backend.

**The fix was aimed.** The grader stalls the orders backend and checks that
`/orders` still gives up in about three seconds. A timeout raised at server
level passes every other check and fails this one, because that is the change
that turns one sick dependency into an outage.

**You can name both failures** the way the error log named them.

<details>
<summary>Hint 1 — the timings are the diagnosis</summary>

```
$ curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://127.0.0.1/orders
$ curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://127.0.0.1/users
```

One fails in milliseconds and one fails after a suspiciously round number of
seconds. A round number is a configured deadline. Find the setting whose value
matches it.

</details>

<details>
<summary>Hint 2 — ask each backend directly</summary>

Take the proxy out of the picture entirely:

```
$ curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://172.32.0.11:8090/orders
$ curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' http://172.32.0.11:8080/users
```

One of them will not answer at all. The other answers correctly, and slowly.
Those two observations are the two different faults.

</details>

<details>
<summary>Hint 3 — bring one back, wait for the other</summary>

The orders backend is a process that is refusing to answer; its admin API can
put it back:

```
$ curl -s -X POST 'http://172.32.0.11:8091/admin/mode?value=normal'
```

The users backend is not broken. `proxy_read_timeout` is per-location as well as
per-server — put the longer one only where the slow route is.

</details>

## What actually happened

**`/orders`**: the backend accepted TCP connections and closed them without
writing a response. nginx logged `upstream prematurely closed connection` and
returned 502 in two milliseconds. Nothing on the proxy could have changed that;
the repair was at the far end.

**`/users`**: the backend was healthy and took six seconds. `proxy_read_timeout`
was three. nginx logged `upstream timed out (110)` and returned 504 at exactly
the deadline. The repair was on the proxy — a longer deadline on that route
only.

Two 5xx, one dashboard line, opposite ends of the wire.

<details>
<summary>Solution</summary>

```bash
# the far end: the orders backend was dead, not misconfigured
$ curl -s -X POST 'http://172.32.0.11:8091/admin/mode?value=normal'

# this end: the slow route gets the longer deadline, and only it
$ sed -n '/location \/users/,/}/p' /etc/nginx/sites-available/gateway
```

```nginx
location /orders {
    proxy_pass http://172.32.0.11:8090;
}

location /users {
    proxy_pass http://172.32.0.11:8080;
    proxy_read_timeout 15s;
}
```

```bash
$ nginx -t && systemctl reload nginx
$ printf 'orders_cause: closed\nusers_cause: timeout\nusers_upstream_seconds: 6\n' \
    > /root/answers/gateway.md
```

</details>

## Carrying this forward

- **502 and 504 are not two shades of the same thing.** One says the upstream
  could not answer; the other says you stopped listening. Separating them takes
  one look at the response time.
- **A round failure time is a configured deadline.** 3.00s, 30.0s, 60.0s — those
  are settings, not symptoms. Go find which one.
- **Restarting the component named in the error is the least likely fix.** The
  proxy is the thing that *reports* upstream failures; it is rarely the thing
  that has them.
- **Raise timeouts per route, never per server.** The blanket raise fixes the
  route you were looking at and hands every other route the same failure mode,
  with workers as the shared resource that runs out.
- **"Make it faster" is not available for work that takes that long.** A
  six-second report is a six-second report; the honest options are a longer
  deadline on that path, or making the work asynchronous.
