---
title: "one client floods the API and everyone gets rate limited"
---

## The situation

One customer is hammering the API. Everyone else is getting 429s.

```
$ for i in $(seq 1 3); do curl -s --interface 127.0.0.3 -o /dev/null -w '%{http_code} ' http://127.0.0.1/health; done
429 429 429
```

127.0.0.3 has sent three requests all day. It is being refused because of what
127.0.0.2 did.

The limiter is not malfunctioning. It is counting exactly what it was told to
count, and getting the right answer to the wrong question:

```
$ curl -s --interface 127.0.0.3 -o /dev/null -D - http://127.0.0.1/health | grep -i x-limiter-saw
X-Limiter-Saw: 127.0.0.1
```

Every request it has ever seen came from 127.0.0.1 — the edge in front of it.
One key, one bucket, and the whole internet sharing it.

## $remote_addr is the last hop, not the client

```nginx
limit_req_zone $binary_remote_addr zone=perip:10m rate=5r/s;
```

`$remote_addr` is the peer of the TCP connection this server accepted. Behind a
proxy, that is the proxy. It is not a lie and not a bug — it is the only address
the kernel can tell nginx about, because it is the only machine that connected.

Everything downstream of a proxy that keys on `$remote_addr` has this property,
and it is not only rate limiting:

- access logs full of one address
- `allow`/`deny` rules matching the proxy
- GeoIP that puts every user in your own datacentre
- abuse tooling that can only ban the load balancer

The client address survives the hop only if something carries it, and the
convention for that is a header the proxy adds:

```nginx
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
```

`$proxy_add_x_forwarded_for` is "whatever the incoming request already had,
plus `$remote_addr`". So the header grows left to right as a request passes
through proxies, oldest first:

```
X-Forwarded-For: 203.0.113.9, 10.0.0.7, 10.0.0.2
                 ^ client      ^ CDN     ^ our edge
```

## The dangerous half

Here is the thing that turns this from a formatting problem into a security
problem: **X-Forwarded-For is written by whoever is talking to you.**

A client can send its own:

```
$ curl -H 'X-Forwarded-For: 9.9.9.9' https://api.example.com/
```

and your edge will faithfully append the real address to it, producing
`9.9.9.9, 203.0.113.9`. The leftmost entry — the one that looks most like "the
original client" — is the one entry in the chain that is entirely
attacker-controlled.

So a limiter that keys on the leftmost entry can be defeated by sending a
different value on every request:

```
$ for i in $(seq 1 10); do curl -H "X-Forwarded-For: 9.9.9.$i" ...; done
200 200 200 200 200 200 200 200 200 200
```

Ten fresh buckets, no limit at all. This is not a hypothetical: it is the
standard bypass for naive `X-Real-IP`/`X-Forwarded-For` handling, and the reason
"just parse the first entry" is wrong in every language and framework.

**The rule: trust an entry only if it was appended by a proxy you control.**
Walk the chain from the right, discarding addresses that are your own
infrastructure, and stop at the first one that is not. Everything to the left of
that is unverifiable — the attacker could have written all of it.

## How nginx expresses that

```nginx
set_real_ip_from 127.0.0.1;      # the trust list — proxies I control
real_ip_header X-Forwarded-For;  # where to look
real_ip_recursive on;            # walk right-to-left past trusted entries
```

`set_real_ip_from` is a **trust list, not a switch**. It answers "whose word do
I take about who the client is". With `127.0.0.1` on it, entries appended by
the edge are believed and entries written by a client are not.

`real_ip_recursive on` makes the walk skip over every trusted address, stopping
at the first untrusted one. With it off, nginx takes the last entry in the
header, which is right for exactly one proxy hop and wrong the moment a CDN
appears in front.

The one thing never to write is the tempting one:

```nginx
set_real_ip_from 0.0.0.0/0;   # "trust everything"
```

That declares the whole internet a trusted proxy, so the leftmost — the forged —
entry wins, and the rate limiter becomes opt-in.

After the fix, `$remote_addr` *is* the client address for everything that runs
after the real_ip module: the limiter key, the access log, `allow`/`deny`. That
is the point of it rewriting the variable rather than exposing a new one.

## Your objective

1. **Per-client limiting.** A flooding client gets 429s; a client that has sent
   three requests does not, at the same moment.
2. **The limit still exists.** A flood from one address is still refused —
   raising the rate until nothing trips is not a fix.
3. **No self-exemption.** A client sending a different `X-Forwarded-For` on
   every request does not get a fresh bucket each time.

Then `/root/answers/realip.md`:

```
before_key: <the address every request was counted under>
xff_trust: <leftmost | rightmost-untrusted>
```

## What you're being graded on

The three requirements, behaviourally, plus one more: traffic still has to reach
the origin. A limiter that is perfectly fair and serves nothing is not a pass.

Requirement 3 is the one that separates the two fixes that both make the
symptom go away. Trusting `0.0.0.0/0` produces beautiful per-client limiting
right up until someone reads your response headers and starts forging.

<details>
<summary>Hint 1 — ask the limiter what it sees</summary>

```
$ curl -s --interface 127.0.0.3 -o /dev/null -D - http://127.0.0.1/health | grep -i x-limiter-saw
```

If that address is the same for every client, the key is the connection's peer
and not the client. Which server block is that response coming from, and what is
in front of it?

</details>

<details>
<summary>Hint 2 — the header is already being sent</summary>

The edge already adds `X-Forwarded-For`. The limiter is not reading it. The
`ngx_http_realip_module` directives are `set_real_ip_from`, `real_ip_header` and
`real_ip_recursive`, and they belong in the server block doing the limiting.

</details>

<details>
<summary>Hint 3 — before you finish, try to cheat</summary>

```
$ for i in $(seq 1 10); do
    curl -s --interface 127.0.0.4 -H "X-Forwarded-For: 9.9.9.$i" -o /dev/null -w '%{http_code} ' http://127.0.0.1/health
  done
```

If those are all 200, your limiter believes whatever a client tells it. The
trust list should contain the proxies you run, and nothing else.

</details>

## What actually happened

The limiter keyed on `$binary_remote_addr`, and from behind the edge that is
always `127.0.0.1`. One bucket for every client.

The fix is to tell the limiter which single address is allowed to speak for
others, and to read the client address from the header that one appends:

```nginx
set_real_ip_from 127.0.0.1;
real_ip_header X-Forwarded-For;
real_ip_recursive on;
```

Not `0.0.0.0/0`, which hands the decision to the caller.

<details>
<summary>Solution</summary>

```nginx
server {
    listen 127.0.0.1:8081;

    set_real_ip_from 127.0.0.1;
    real_ip_header X-Forwarded-For;
    real_ip_recursive on;

    location / {
        limit_req zone=perip burst=2 nodelay;
        proxy_pass http://172.32.0.11:8080;
        add_header X-Limiter-Saw $remote_addr always;
    }
}
```

```bash
$ nginx -t && systemctl reload nginx
$ printf 'before_key: 127.0.0.1\nxff_trust: rightmost-untrusted\n' > /root/answers/realip.md
```

</details>

## Carrying this forward

- **`$remote_addr` is the last hop.** Behind any proxy, every per-client
  decision keyed on it is a per-proxy decision — limits, bans, logs, geo.
- **`X-Forwarded-For` is caller-controlled input.** Treat it exactly like a query
  parameter: useful, and never authoritative on its own.
- **Trust from the right.** The rightmost entry not written by your own
  infrastructure is the best available truth. The leftmost is the attacker's
  favourite field.
- **A trust list is not a feature flag.** `set_real_ip_from 0.0.0.0/0`,
  `trust_proxy: true`, `ALL` — every framework has this footgun, and every one
  of them turns the limiter into an opt-in.
- **Test the bypass before you call it fixed.** Forge the header and watch what
  happens. If it works, you have built a limiter that only limits honest
  clients.
