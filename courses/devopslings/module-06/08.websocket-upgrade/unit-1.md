---
title: "the socket will not open, and once it does it dies after sixty seconds"
---

## The situation

Straight at the application, the live feed works:

```
$ wsprobe http://172.32.0.11:8080/ws --idle 2
ok: echoed before and after 2s idle
```

Through the proxy, it does not:

```
$ wsprobe http://127.0.0.1/ws --idle 2
handshake failed: HTTP/1.1 426 Upgrade Required
```

`426 Upgrade Required` is the application saying *you asked me for this URL as
ordinary HTTP*. The request reached it, and by the time it did, the part that
made it a WebSocket handshake was gone.

And there is an older report nobody solved: on a test box the feed did connect,
and then died after about a minute, every time. It was blamed on the client's
reconnect logic. It was not the client.

## A WebSocket starts as an HTTP request that asks to stop

```
GET /ws HTTP/1.1
Host: api.internal
Upgrade: websocket
Connection: Upgrade
Sec-WebSocket-Key: x3JJHMbDL1EzLkh9GBhXDw==
Sec-WebSocket-Version: 13
```

The server answers `101 Switching Protocols`, echoes back a hash of the key,
and from that point the connection is not HTTP any more — both ends speak
frames over the same socket, in both directions, for as long as it stays open.

Two properties of that make proxies awkward, and each is one half of this
lesson.

**`Upgrade` and `Connection` are hop-by-hop headers.** HTTP defines two classes
of header: end-to-end ones, which every intermediary must forward, and
hop-by-hop ones, which apply to *this* connection only and which an intermediary
must consume rather than pass on. `Connection`, `Upgrade`, `Keep-Alive`,
`TE`, `Transfer-Encoding` and `Proxy-Authenticate` are the hop-by-hop set.

nginx obeys that rule, which is why the upstream saw a plain `GET /ws`. Getting
a WebSocket through requires explicitly re-adding them for the next hop:

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
```

`proxy_http_version 1.1` is not optional and is the part most often missed:
nginx talks HTTP/1.0 upstream by default, and `Upgrade` does not exist in
HTTP/1.0. Without it the other two lines cannot help.

The `$http_upgrade` variable rather than a literal `websocket` matters too — it
forwards whatever the client asked to upgrade to, and it is empty for ordinary
requests, which keeps the same block from claiming to upgrade everything.

**An idle WebSocket looks exactly like a dead upstream.** `proxy_read_timeout`
means "give up if the upstream sends nothing for this long", and it defaults to
60 seconds. For a request/response that is a sensible safety net. For a socket
that exists precisely so the server *can* say nothing until there is news, it is
a guillotine on a timer — which is why the failure was so regular that it looked
like a client bug.

```nginx
proxy_read_timeout 300s;
proxy_send_timeout 300s;
```

That number is a judgement about the feed, not a magic value: it has to exceed
the longest expected silence. The robust arrangement is to make silence rare —
have the application send a WebSocket ping every 30 seconds — and keep the
timeout as a backstop rather than the only thing holding the connection up.

## Do not raise it for everything

The tempting version is one `proxy_read_timeout 300s;` at server level. It
fixes the socket, and it also tells the proxy to wait five minutes on every
ordinary request to a backend that has wedged. Workers are finite; a stalled
dependency then holds all of them, and one broken route becomes a down site.

The two cases genuinely differ — for `/ws` a long silence is normal, for
`/health` it is a fault — so they need different deadlines, which is what a
separate `location` is for.

## Your objective

1. `wsprobe http://127.0.0.1/ws --idle 90` succeeds.
2. With the application stalled, `http://127.0.0.1/health` returns within 10
   seconds. nginx's own default is 60, and the socket needs minutes — so this
   is not "leave it alone", it is a second, shorter deadline for the route
   where silence means something is wrong.

Then `/root/answers/ws.md`:

```
handshake_code: <the status the proxied handshake got before the fix>
idle_limit_seconds: <how long an idle proxied socket survived, before you changed any timeout>
```

## What you're being graded on

**The socket opens and survives ninety seconds of silence.** Both halves — a
config with the upgrade headers but the default timeout passes the handshake and
fails the idle.

**Ordinary requests give up inside ten seconds.** The grader stalls the
application and times a plain request. This is what rejects the server-level
raise — and it also means picking a deadline for ordinary traffic rather than
inheriting one.

**Both numbers.** 426 is what the upstream said when the handshake arrived
stripped, and 60 is nginx's default `proxy_read_timeout` — the one that was
killing the connection while nothing in the config mentioned it.

<details>
<summary>Hint 1 — compare the two requests</summary>

The application answers `/ws` correctly when asked directly and 426 when asked
through the proxy. The difference is in the headers that arrived. Which headers
does a WebSocket handshake need, and what class of header are they?

</details>

<details>
<summary>Hint 2 — three directives, and the order they matter in</summary>

`proxy_http_version 1.1` first: `Upgrade` does not exist in HTTP/1.0, so
forwarding it over 1.0 achieves nothing. Then `Upgrade: $http_upgrade` and
`Connection: "upgrade"`.

</details>

<details>
<summary>Hint 3 — it opens, and then it does not last</summary>

```
$ time wsprobe http://127.0.0.1/ws --idle 90
```

Watch how long it survives, and compare that number with nginx's default
`proxy_read_timeout`. Then put the longer one where it belongs — not on the
whole server.

</details>

## What actually happened

The proxy block was an ordinary reverse-proxy block, correct for every request
the application serves except the one trying to stop being a request.

- `Upgrade` and `Connection` are hop-by-hop, so nginx consumed them and the
  upstream saw a plain `GET /ws` and answered 426.
- Even once forwarded, the connection was subject to `proxy_read_timeout`,
  which defaults to 60s and which an idle socket trips by design.

The repair is a `location /ws` with HTTP/1.1 upstream, the two headers
re-added, and a deadline long enough for silence — leaving the rest of the
server on its short one.

<details>
<summary>Solution</summary>

```nginx
location /ws {
    proxy_pass http://172.32.0.11:8080;
    proxy_set_header Host $host;

    proxy_http_version 1.1;
    proxy_set_header Upgrade $http_upgrade;
    proxy_set_header Connection "upgrade";

    proxy_read_timeout 300s;
    proxy_send_timeout 300s;
}

location / {
    proxy_pass http://172.32.0.11:8080;
    proxy_set_header Host $host;

    proxy_read_timeout 10s;
}
```

```bash
$ nginx -t && systemctl reload nginx
$ wsprobe http://127.0.0.1/ws --idle 90
ok: echoed before and after 90s idle
$ printf 'handshake_code: 426\nidle_limit_seconds: 60\n' > /root/answers/ws.md
```

</details>

## Carrying this forward

- **Hop-by-hop headers do not survive a proxy, by design.** `Connection`,
  `Upgrade`, `Keep-Alive`, `TE`, `Transfer-Encoding`. If a protocol depends on
  one, the proxy has to be told to re-send it.
- **`proxy_http_version 1.1` is the line people forget.** Upgrades, keepalive to
  upstreams and chunked request bodies all need it.
- **A failure that always takes the same round number of seconds is a
  timeout.** 60s, 30s, 5m — before blaming a client's reconnect loop, find the
  deadline whose value matches.
- **Long-lived connections need their own location.** Their normal behaviour —
  saying nothing for minutes — is indistinguishable from the failure everything
  else's timeouts exist to catch.
- **Prefer application-level pings to a long timeout alone.** A ping every 30
  seconds keeps the connection provably alive and lets the timeout stay short
  enough to still catch a genuinely dead upstream.
