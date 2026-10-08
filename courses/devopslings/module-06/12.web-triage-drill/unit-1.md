---
title: "some requests to the shop fail or hang since last night's deploy"
---

## The situation

```
$ shop-smoke
```

Since last night's deploy, some requests to the shop fail or hang. That is the
entire ticket, and it will be the entire ticket every time you run this lesson
— because the fault is drawn at random from five, and each is a different way a
proxy can break a request that the application behind it would have answered.

`shop-smoke` walks one customer visit through the gateway on this box: two API
calls, a report, the page's script, a 5 MB upload and a websocket. Each line is
a step, its status and how long it took. The gateway is nginx
(`/etc/nginx/sites-available/shop`, `/etc/nginx/conf.d/shop.conf`). Behind it,
on `172.32.0.11`, the shop API listens on `:8080` and reports on `:8090`. Each
has an admin API one port up that tells you exactly what it was asked for.

Which step fails tells you where to look. It does not tell you why — the
answer is always one hop further than the status code.

## Your objectives

- Make `shop-smoke` pass by repairing the gateway where the deploy broke it
- Write `/root/answers/triage.md`, three lines:

  ```
  cause:     <what was wrong, in a few words>
  evidence:  <the command or log line that proved it>
  detection: <a signal and a threshold that would have paged first>
  ```

## What you're being graded on

The grader walks the visit itself, then checks that the repair is at the cause
rather than around it:

- **every route answers from the service that owns it**, and the shop API is
  asked for the path it owns — a body served from nginx, or a `rewrite`
  standing in for `proxy_pass`, is not a repair
- **reports take their five seconds** and are waited for. The reports service
  is put back to five seconds before grading, so making it fast fixes nothing.
- **the rest of the gateway kept its deadlines**: with the shop API stalled, an
  ordinary API request still gives up in under five seconds
- **uploads are still bounded**: 5 MB goes through and 64 MB is refused with 413
- **the asset cache is still a cache**: a new build is served under its new URL,
  and ten requests for one asset cost the origin at most two
- **the limiter on `/api/` is untouched**, and so is last night's
  `access.log.1`. It is full of 429s, and every one of them is a scraper on
  `172.32.0.12` being refused — the limiter working, not the fault. A flood from
  one client must still be refused, and a quiet client must not pay for it.

And `triage.md`: `cause` must describe the fault that was seeded; `evidence`
must be the command or log line that proves that fault; `detection` must name a
signal that fits it *and* a number.

<details>
<summary>Hint 1 — the questions, in order</summary>

```
$ shop-smoke                                         # which step, what status, how long
$ curl -si http://127.0.0.1/<the failing route>      # whose body is it? X-Upstream?
$ tail /var/log/nginx/error.log                      # what the gateway says it did
$ curl -s http://172.32.0.11:8081/admin/received     # what the next hop was asked for
$ curl -s http://172.32.0.11:8081/admin/last         # ...with which headers
$ curl -s -o /dev/null -w '%{http_code} %{time_total}\n' http://172.32.0.11:8090/reports/daily
```

Ask the same request of the application directly. If it answers there and not
through the gateway, the difference is the gateway's, and the next hop's own
record says what that difference was.

</details>

<details>
<summary>Hint 2 — who wrote the status code?</summary>

A 404 or a 426 whose body names the application came from the application: the
request arrived, and arrived wrong. A 413, a 502 or a 504 in nginx's own HTML
page came from the gateway, and the upstream may never have heard of the
request. A 200 with the wrong content is the hardest of all, because nobody
thinks they failed — `X-Cache-Status` says whether anybody asked the origin.

</details>

<details>
<summary>Hint 3 — repair the route, not the server</summary>

Every fault here is one route that lost something it needed. Putting it back on
that route is the fix. Raising a timeout or a body limit for the whole server,
turning the cache off, or deleting the limiter all make the smoke test pass and
take something away from every other route.

</details>

## What actually happened

| Fault | What the deploy did | What `shop-smoke` shows | The tell |
|---|---|---|---|
| slash | `proxy_pass http://172.32.0.11:8080;` on `/api/` — the trailing slash gone | `/api/*` 404, instantly | the body is the API's `no route: /api/users`; `/admin/received` has `GET /api/users` |
| timeout | the `/reports/` location lost `proxy_read_timeout 15s` | `/reports/daily` 504 at 3.0s | `upstream timed out` in error.log; the service itself takes 5s |
| cache | `proxy_cache_key` built from `$uri` instead of `$request_uri` | `/asset.js?v=2` 200, wrong content | `X-Cache-Status: HIT` on a URL never asked for; no request at the origin |
| body | `client_max_body_size 20m` dropped from `/upload` | upload 413 | nginx's own 413 page, `client intended to send too large body` in error.log, nothing at the origin |
| upgrade | `Upgrade` and `Connection` no longer set on `/ws` | websocket 426 | the 426 body is the API's; `/admin/last` shows a plain GET |

The red herring, every run: `/var/log/nginx/access.log.1`, thousands of 429s
from last night. They are all one address, `172.32.0.12`, a scraper the limiter
was added for. The limiter refused it, and customers were served around it.

<details>
<summary>Solution</summary>

Ask in order and repair at the first question that answers, on the route that
broke.

```bash
shop-smoke

# slash: a 404 in the upstream's words
curl -s http://127.0.0.1/api/users                   # no route: /api/users
curl -s http://172.32.0.11:8081/admin/received
#   location /api/ { ... proxy_pass http://172.32.0.11:8080/; }

# timeout: a 504 at exactly the gateway's deadline
grep 'timed out' /var/log/nginx/error.log
curl -s -o /dev/null -w '%{time_total}\n' http://172.32.0.11:8090/reports/daily
#   location /reports/ { proxy_read_timeout 15s; ... }

# body: a 413 the upstream never saw
grep 'too large' /var/log/nginx/error.log
#   location = /upload { client_max_body_size 20m; ... }

# upgrade: a 426 from the application
wsprobe http://127.0.0.1/ws; curl -s http://172.32.0.11:8081/admin/last
#   location = /ws { proxy_set_header Upgrade $http_upgrade;
#                    proxy_set_header Connection "upgrade"; ... }

# cache: right status, wrong build
curl -si 'http://127.0.0.1/asset.js?v=2' | grep -i x-cache
#   proxy_cache_key "$scheme$request_method$host$request_uri";
rm -rf /var/cache/nginx/shop/*

nginx -t && systemctl reload nginx && shop-smoke
```

Then, for example:

```
cause: reports route inherits the 3s proxy_read_timeout, shorter than the 5s a report takes
evidence: error.log: upstream timed out while reading response header; :8090 takes 5s directly
detection: 504s on /reports/ above 0.5% for 5 minutes
```

</details>

## Carrying this forward

- **Find who wrote the status code before asking why.** The application's 404
  and nginx's 413 are both 4xx, and they are answers from different machines.
- **Ask the next hop what it saw.** Every fault here is a difference between
  the request that left the client and the request that arrived, and the
  receiving end's record is the only place it is visible.
- **A deadline, a limit and a cache key belong to a route.** Raising them for
  the server makes the ticket go quiet and changes every route you did not
  look at.
- **A log full of errors is a question, not an answer.** Whose errors, and was
  anything wrong when they were written?

Run the lesson again. The fault moves, and the questions do not.
