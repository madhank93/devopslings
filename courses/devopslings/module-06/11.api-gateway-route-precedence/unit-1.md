---
title: "two routes match, and the gateway picks the other one"
---

## The situation

Four services behind one gateway on port 80 of this box:

```
/api/v1/...          -> the legacy API      (172.32.0.11:8080)
/api/v2/...          -> the v2 API          (172.32.0.11:8080)
/api/v2/reports/...  -> the reports service (172.32.0.11:8090)
/api/admin/...       -> the admin API, token required
```

Reporting was split into its own service last month and the route was added.
Its requests still arrive at the v2 API:

```
$ curl -s http://127.0.0.1/api/v2/reports/daily
no route: /v2/reports/daily
```

Each upstream records what it was actually asked for, which is the only
witness that matters here:

```
curl -s http://172.32.0.11:8081/admin/received   # the API
curl -s http://172.32.0.11:8091/admin/received   # reports
```

The routes are in `/etc/nginx/sites-available/gateway`. Moving the reports
block to the top of the file has already been tried.

## Your objectives

- Each of the four request paths reaches the service it names
- `/api/admin/...` still answers 401 to a request with no token, and the
  request does not reach the admin service on its way to being refused
- The rate limiter still counts each client separately

## What you're being graded on

Four requests, each from its own client address, each checked against what the
upstream says it received — not against the status code, which can be right for
the wrong reason. Then `/api/admin/users` with no `Authorization` header must
be 401 and must not appear in the admin service's received list. Then twelve
requests from one client must be partly refused and three from a second client
must not be. You also fill in `/root/answers/gateway.md`.

<details>
<summary>Hint 1 — find out which block served it, rather than guessing</summary>

Both of these match `/api/v2/reports/daily`:

```nginx
location /api/v2/reports/ { ... proxy_pass http://reports; }
location ~ ^/api/v2/(.*)$ { ... proxy_pass http://api;     }
```

The upstreams say which one won:

```
curl -s -X POST http://172.32.0.11:8091/admin/reset
curl -s http://127.0.0.1/api/v2/reports/daily
curl -s http://172.32.0.11:8081/admin/received   # the v2 API got it
curl -s http://172.32.0.11:8091/admin/received   # reports did not
```

Note what this rules out. The reports block is not misspelled, the upstream is
not down, and the rewrite is not wrong — that block never ran.

</details>

<details>
<summary>Hint 2 — nginx does not read locations in order</summary>

For each request nginx works through *kinds* of location, not lines of file:

1. `location = /path` — an exact match. If one matches, it stops here.
2. All prefix locations are searched for the **longest** match. That match is
   remembered, not used yet.
3. If the longest prefix match was declared `^~`, nginx stops and uses it.
4. Otherwise the **regex** locations (`~`, `~*`) are tried **in the order they
   appear in the file**, and the first one that matches wins.
5. Only if no regex matches does nginx fall back to the prefix match from 2.

So a regex beats a longer plain prefix, always, whatever order they are written
in. That is why moving the block changed nothing: step 2 already found it, and
step 4 threw it away.

```
man 8 nginx  # or the location directive in the nginx docs
```

Two of these routes are prefixes, one is a regex, and that is the whole bug.

</details>

<details>
<summary>Hint 3 — two ways to fix it, and one of them is smaller</summary>

**Mark the prefix `^~`.** One character, and step 3 above now stops before the
regexes are tried:

```nginx
location ^~ /api/v2/reports/ { ... }
```

**Or stop using a regex for the v2 route.** `location /api/v2/` is a prefix, so
both routes go through step 2, and the longest prefix — the reports one — wins:

```nginx
location /api/v2/ {
    rewrite ^/api/v2/(.*)$ /v2/$1 break;
    proxy_pass http://api;
}
```

Either is correct. The second is worth preferring in a config that will grow:
prefixes compose by specificity, and every regex you add is another rule that
depends on where it sits.

Whatever you change, leave the `if` in the admin block and the `limit_req`
where the client can still be told apart — both are graded.

</details>

<details>
<summary>Solution</summary>

```nginx
location ^~ /api/v2/reports/ {
    rewrite ^/api/v2/reports/(.*)$ /reports/$1 break;
    proxy_pass http://reports;
}
```

```
$ curl -s http://127.0.0.1/api/v2/reports/daily
reports: daily rollup
$ curl -s http://127.0.0.1/api/v2/orders
v2 api: orders 1001 1002
```

### The part worth remembering

**Route precedence is a property of the kind of match, not of the order.**
Prefix, exact and regex are three different mechanisms with a fixed order
between them, and only regexes are read top to bottom. Every gateway has a
version of this rule — nginx's exact/`^~`/regex/longest-prefix, Envoy and
Traefik's explicit priorities, an ALB's numbered rules — and none of them is
"first line wins". Read your gateway's rule once, properly, and the whole class
of bug disappears.

**The first guess is worth noticing rather than just discarding.** Moving the
block to the top is what you would do if the gateway matched in file order, and
the fact that it changed nothing is evidence: whatever picks the route, it is
not reading the file the way you are. A fix that does nothing has told you
something.

**Ask the next hop what it received.** The status code said 404 and the body
said `no route: /v2/reports/daily`, which is the v2 API answering honestly about
a path it does not have. The gateway's own access log would have shown a
perfectly normal request. Two seconds with `/admin/received` on each upstream
turned "reporting is broken" into "the reports block never ran".

**A more specific route is not automatically a higher-priority route.** It is
tempting to assume specificity wins because it usually reads that way. Here the
longer, narrower, newer route lost to a broader one written a year earlier —
and it will keep losing silently every time somebody adds a path under `/api/v2/`
that deserves its own service.

**Check what else the route change carries.** The block you are editing is
also where the token check and the rate limit live. Rewriting a location to fix
the routing is exactly how an auth check gets dropped, and nothing about the
routing tests would notice.

</details>
