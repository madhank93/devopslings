---
title: "every path through the proxy is off by one segment"
---

## The situation

Four routes through the gateway, four 404s:

```
$ curl -s http://127.0.0.1/api/users
no route: /api/users
```

Read that body again. `no route:` is not an nginx error page — nginx's 404 is
HTML with a version banner on it. That body came from the application. The
request reached the upstream, the upstream answered, and the answer was "I have
no such path".

So the application is up, it is reachable, and it is being asked for something
it does not have. Asked directly, it is perfectly healthy:

```
$ curl -s http://172.32.0.11:8080/users
users: alice bob carol
```

`/users` works. `/api/users` does not exist. Nobody sent `/api/users` to the
upstream — the client sent it to *nginx*, and nginx passed it on unchanged.

## The one question worth asking at a proxy

**What did the next hop actually receive?**

Almost every proxy bug is the gap between the request you sent and the request
that arrived, and almost every proxy bug is debugged by people staring at the
one they sent. The upstream in this sandbox records every request line exactly
as it got it:

```
$ curl -s http://172.32.0.11:8081/admin/received
GET /api/users
GET /api/orders
GET /api/version
GET /pages//intro
```

There it is, without a single guess. Three requests arrived with a prefix that
should have been stripped. One arrived with two slashes in it.

In a real system this is `tcpdump -A -s0 port 8080`, or an access log on the
upstream with `$request` in it, or `proxy_set_header X-Debug-Path $uri`. The
tool changes; the question does not.

## The rule: proxy_pass with a URI, and without

This is the whole lesson, and it is one sentence:

> If `proxy_pass` has a URI part after the host, nginx **replaces** the part of
> the request URI that the location matched with it. If it has no URI part,
> nginx forwards the request URI **unchanged**.

A "URI part" is anything after the host and port — including a bare `/`. That
is why a single character changes everything:

```nginx
location /api/ { proxy_pass http://app:8080;  }   # -> /api/users
location /api/ { proxy_pass http://app:8080/; }   # -> /users
```

The first has no URI part. `/api/users` goes to the upstream as `/api/users`.
The second has a URI part of `/`, so the matched prefix `/api/` is replaced by
`/`, and the upstream is asked for `/users`.

Neither is wrong in general. Which one you want depends entirely on whether the
upstream expects to see the prefix. An application mounted at `/api` wants the
first. An application that owns its own root — like this one — wants the second.

## The second trap: what exactly gets replaced

The replacement is of **the text the location matched**, not "the prefix, plus
the slash you were probably thinking of".

```nginx
location /docs { proxy_pass http://app:8080/pages/; }
```

A request for `/docs/intro` matches the location on the text `/docs`. That text
is replaced by `/pages/`, and what remains — `/intro`, still carrying its
leading slash — is appended:

```
/docs/intro  ->  /pages/  +  /intro  ->  /pages//intro
```

Two slashes. To an upstream, `/pages//intro` and `/pages/intro` are different
strings and there is no rule saying they must mean the same thing. This one
404s.

There is a second, nastier consequence of a prefix location with no trailing
slash: it matches on text, not on path segments.

```
$ curl -s http://127.0.0.1/docsfoo
no route: /pages/foo
```

`/docsfoo` matched `/docs` too, and got proxied as `/pages/foo`. A location
that is meant to mean "the /docs tree" and is written without the trailing
slash also claims every sibling path that happens to start with those five
characters.

The fix is to make the matched text include the separator, so that what is left
over does not start with one:

```nginx
location /docs/ { proxy_pass http://app:8080/pages/; }
```

## Why "rewrite" is the wrong instinct

The reflex when a proxied path is wrong is to reach for `rewrite`:

```nginx
location /api/ {
    rewrite ^/api/(.*)$ /$1 break;
    proxy_pass http://app:8080;
}
```

That works. It is also a second mechanism doing a job the first one already
does, and now the path can be changed in two places — which means the next
person has to read both to know what the upstream gets. `rewrite` earns its
place when the transformation is genuinely not a prefix swap: a regex capture,
a conditional, a query-string rearrangement. Stripping a prefix is not that.

This exercise rejects a `rewrite` for that reason.

## Your objective

1. Make all four routes work through the gateway on `127.0.0.1`:

   ```
   /api/users     -> users: alice bob carol
   /api/orders    -> orders: 1001 1002
   /api/version   -> upstream 1.0
   /docs/intro    -> docs: introduction
   ```

   In the proxy configuration, still going to `172.32.0.11:8080`, with no
   `rewrite`.

2. Write `/root/answers/proxy.md`, exactly two lines:

   ```
   api_before: <path>
   docs_before: <path>
   ```

   What the upstream received, before your fix, for `/api/users` and for
   `/docs/intro`. They are in its record — and they stay there after you fix
   it, so you can look at any point.

## What you're being graded on

**All four routes return the upstream's bodies.** Not three.

**The upstream is actually being asked.** A verification request goes through
the gateway with a random token in its query string, and that token has to turn
up in the upstream's own record. `return 200 'users: alice bob carol';` in an
nginx location satisfies every body check and proxies nothing — it would pass a
naive grader, and it would keep passing after the application changed.

**No `rewrite`, and both routes still point at `172.32.0.11:8080`.**

**You can say what arrived.** `/api/users` and `/pages//intro`, copied from the
record verbatim — the double slash included, because it is the fault.

<details>
<summary>Hint 1 — get the evidence first</summary>

```
$ curl -s http://172.32.0.11:8081/admin/received
```

Every request as the upstream received it. Compare each line with the path you
asked nginx for. Two different things are wrong, and this shows both without
reading any configuration.

</details>

<details>
<summary>Hint 2 — the rule for /api/</summary>

`proxy_pass http://host:port;` forwards the request URI unchanged.
`proxy_pass http://host:port/;` replaces the matched location prefix with `/`.

The upstream's route is `/users`, and the client asks for `/api/users`.

</details>

<details>
<summary>Hint 3 — the rule for /docs</summary>

What gets replaced is exactly the text the location matched. `location /docs`
matches `/docs`, leaving `/intro` — including its leading slash — to be
appended to `/pages/`.

Make the location match the separator too, and the leftover no longer has one.
While you are there, try `curl http://127.0.0.1/docsfoo` and see what a prefix
location without a trailing slash also claims.

</details>

## What actually happened

```
location /api/ { proxy_pass http://172.32.0.11:8080; }
```

No URI part, so the request URI went through untouched: the upstream was asked
for `/api/users` and it only has `/users`.

```
location /docs { proxy_pass http://172.32.0.11:8080/pages/; }
```

A URI part, so the matched text was replaced — and the matched text was `/docs`
without the separator, so `/docs/intro` became `/pages/` + `/intro` =
`/pages//intro`.

Both fixes are one character:

```nginx
location /api/  { proxy_pass http://172.32.0.11:8080/; }
location /docs/ { proxy_pass http://172.32.0.11:8080/pages/; }
```

<details>
<summary>Solution</summary>

```nginx
server {
    listen 80 default_server;
    server_name _;

    location /api/ {
        proxy_pass http://172.32.0.11:8080/;
        proxy_set_header Host $host;
    }

    location /docs/ {
        proxy_pass http://172.32.0.11:8080/pages/;
        proxy_set_header Host $host;
    }
}
```

```bash
$ nginx -t && systemctl reload nginx
$ curl -s http://127.0.0.1/api/users
users: alice bob carol
$ printf 'api_before: /api/users\ndocs_before: /pages//intro\n' > /root/answers/proxy.md
```

</details>

## Carrying this forward

- **Ask what the next hop received.** Not what you sent. An upstream access log,
  a capture, or an echo endpoint settles in one line what an afternoon of
  reading configuration will not.
- **A 404 whose body came from the application is a routing bug, not a
  deployment one.** Learn what each layer's error pages look like, so you can
  tell whose 404 you are holding.
- **`proxy_pass` with a URI replaces; without one it forwards.** A bare `/` is a
  URI. This is the single most reliable trap in nginx configuration, and it is
  worth being able to recite.
- **Write prefix locations with the trailing slash.** `location /docs` also
  matches `/docsfoo`, and leaves a leading slash behind when its prefix is
  replaced. `location /docs/` does neither.
- **Reach for `rewrite` last.** If the transformation is a prefix swap,
  `proxy_pass` already does it, in one place, visibly.
