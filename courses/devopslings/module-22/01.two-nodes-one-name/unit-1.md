---
title: "Two servers, one name"
---

## The situation

The shop is reached at one name, `www`. That name is an address held by the
load balancer, which passes each request on to an app server:

```
ops ── www ── lb1 ── web1
                     web2   (idle)
```

```
$ for i in 1 2 3 4; do curl -s http://www/; done
hello from web1
hello from web1
hello from web1
hello from web1
```

web2 runs the same code and answers if you ask it directly
(`curl http://web2:8080/`). Nobody does. If web1 stops, the shop stops.

## Your objectives

1. Requests to `www` are shared between web1 and web2.
2. Either server can crash and `www` keeps answering, quickly.
3. A crashed server that comes back gets traffic again by itself.

Everything happens in `/ha/haproxy.cfg`. Both load balancers read it, and they
reload within a second of you saving it. If HAProxy rejects your file, it says
why at the bottom of `/ha/lb1/log` and keeps the old config.

## What you're being graded on

- **Both serve.** 40 requests to `www`, all `200`, and each server answers
  some of them.
- **Either can die.** The grader crashes web1 with `docker kill`, waits 8
  seconds, and sends 40 more. Every one must succeed, and each in under a
  second. Then it restarts web1 and does the same to web2.
- **The dead come back.** After the restart, the server has to show as `UP` in
  lb1's stats within 30 seconds.

## Try it yourself

```
node kill web1
for i in $(seq 6); do curl -s -w ' %{time_total}s\n' http://www/; done
curl -s 'http://lb1:8404/stats;csv' | cut -d, -f1,2,18
node start web1
```

The stats line is HAProxy's opinion of each server. Watch it while you kill
things.

<details>
<summary>Hint 1 — adding the second server is half of it</summary>

Add a `server web2 172.29.22.22:8080` line and requests alternate. Now
`node kill web1` and send a few requests. Half of them fail.

HAProxy is still sending web1 its share. Nothing told it web1 is gone, because
nothing is asking. The stats column says `no check`.

</details>

<details>
<summary>Hint 2 — ask, regularly</summary>

`check` on a server line makes HAProxy probe that server on a timer. After
`fall` failed probes in a row it marks the server DOWN and stops sending it
anything. After `rise` good ones it is UP again.

By default the probe only opens a TCP connection. `option httpchk GET /health`
in the backend makes it an HTTP request that has to return 2xx or 3xx.

`inter` is the gap between probes, 2 seconds by default. `inter` times `fall`
is roughly how long a dead server keeps getting traffic.

</details>

<details>
<summary>Hint 3 — retries are not a health check</summary>

`retries 3` with `option redispatch` also makes the errors go away: a request
that cannot connect to web1 is retried on web2. But each of those requests
waits out the connect timeout first, so users see a two-second stall on every
other request, and HAProxy still believes web1 is fine. The grader times each
request for this reason.

</details>

<details>
<summary>Solution</summary>

```
frontend www
    bind :80
    default_backend app

backend app
    balance roundrobin
    option httpchk GET /health
    server web1 172.29.22.21:8080 check inter 1s fall 2 rise 2
    server web2 172.29.22.22:8080 check inter 1s fall 2 rise 2
```

### Why the check is the whole point

A load balancer with two servers and no health check splits traffic. It does
not make the service survive anything. When web1 dies, half of all requests
are still sent to it.

The health check closes the loop. HAProxy asks every server, every second, and
stops sending traffic to one that stops answering. With `inter 1s fall 2`, a
dead server is out of rotation about two seconds after it dies. Those two
seconds are the price of the design. A smaller `inter` shrinks them and sends
more probes; `fall 1` shrinks them more, and ejects a server for one slow
answer.

`rise 2` makes the return deliberate. A server that answers once is not
necessarily healthy, and one that flaps in and out of rotation is worse than
one that stays out.

### What is still single

Look at the diagram again. There are two app servers now, and one of
everything else: one address, held by lb1 only, and one database. The next
lesson goes looking for all of them.

</details>
