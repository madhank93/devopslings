---
title: "the brute-force jail is about to ban the load balancer"
---

## The situation

A fail2ban jail, `web-login`, watches the login service's access log and bans
any address that racks up five failed logins (HTTP 401) in ten minutes. Ask it
what it would do with the log as it stands:

```
$ fail2ban-regex /var/log/app/access.log web-login
...
Lines: 44 lines, 0 ignored, 39 matched, 5 missed
$ fail2ban-regex -o ip /var/log/app/access.log web-login | sort | uniq -c
     31 10.9.0.9
      8 192.0.2.77
```

`10.9.0.9` is the load balancer. Every user of the site comes through it, so
the moment this jail runs, it bans the site's front door. fail2ban's own log
will say it stopped a brute-force attack.

Someone has already suggested adding `10.9.0.9` to `ignoreip` and moving on.

The log is nginx's `combined` format with one extra field on the end, the
request's `X-Forwarded-For` header:

```
10.9.0.9 - - [28/Sep/2026:20:05:50 +0000] "POST /login HTTP/1.1" 401 17 "-" "Mozilla/5.0" "198.51.100.23"
```

## Your objectives

Fix the jail (`/etc/fail2ban/jail.local` and
`/etc/fail2ban/filter.d/web-login.conf`) so that:

- whoever is really hammering `/login` gets banned;
- the load balancer is never banned;
- a user who mistypes a password once or twice is never banned;
- nobody can get someone else banned, or dodge a ban, by sending a made-up
  `X-Forwarded-For` header.

Keep the jail enabled. Then write `/root/answers/fail2ban.md`:

```
wrongly_banned_ip: <the address the original jail would have banned>
real_client_in: <the log field that carries the real client address>
```

## What you're being graded on

The grader starts a private fail2ban-server with your configuration, points the
jail at fresh traffic with new, random client addresses, and reads back which
addresses it banned. It includes the load balancer's health checks, users with
a couple of typos, a brute-force run through the load balancer, and a host
connecting directly with a forged header. Hard-coding this log's addresses will
not pass. It also checks `fail2ban-client -t` and the answer file.

<details>
<summary>Hint 1 — whose failures are these, really?</summary>

Read the log, not just the counts. Group the 401s by the last field instead of
the first:

```
$ awk '$9 == 401 {print $1, $NF}' /var/log/app/access.log | sort | uniq -c | sort -rn
```

The first field is whoever opened the TCP connection to this box. Behind a
load balancer, that is the load balancer for every proxied request. Now ask
what `ignoreip = 10.9.0.9` would leave the jail able to ban.

</details>

<details>
<summary>Hint 2 — which part of the header can you believe?</summary>

`X-Forwarded-For` is a request header, so a client can send any value it likes.
A load balancer *appends* the address it accepted the connection from, so on a
request that came through it, the **last** entry is the one the load balancer
vouches for and everything before it is whatever the client typed. Look at the
`203.0.113.66` lines.

And a request that did *not* come through the load balancer has no one
vouching for its header at all. Look at `192.0.2.77`.

</details>

<details>
<summary>Hint 3 — two failregex lines, in order</summary>

A filter can list several `failregex` lines, one per indented line; fail2ban
uses the first one that matches. `<ADDR>` matches an IP address and nothing
else. One regex for lines whose peer is `10.9.0.9`, taking the last
forwarded address; one for everything else, taking the peer. Then decide what
should happen to the load balancer's own requests that carry no forwarded
address at all.

Test before you rely on it:

```
$ fail2ban-regex -o ip /var/log/app/access.log web-login | sort | uniq -c
$ fail2ban-client -t
```

</details>

<details>
<summary>Solution</summary>

**Why the jail was wrong.** A proxy terminates the client's connection and
opens its own to the backend, so the backend's first log field, `$remote_addr`,
is the proxy for every proxied request. A per-source rule like fail2ban's then
adds every user's failures together and bans the one thing they have in
common. `ignoreip` on the load balancer stops that ban, and also stops every
other ban. The brute-force run arrives from `10.9.0.9` too, so a jail that
ignores it bans nobody.

**The fix** is to count failures against the client address, taken only from
a source you trust:

- peer is the load balancer: use the **last** `X-Forwarded-For` entry, the one
  it appended. Taking the first entry lets `203.0.113.66` put a fresh forged
  value there on every request and never reach `maxretry`.
- any other peer: use the peer address and ignore the header. Believing
  `X-Forwarded-For` from anyone ("trust everyone") lets `192.0.2.77` get
  `198.51.100.23` banned while escaping itself.
- the load balancer's own requests (health checks, `X-Forwarded-For: -`) fall
  through to the peer rule, so `ignoreip` still exempts `10.9.0.9`. Now it only
  exempts the load balancer, not everyone behind it.

`/etc/fail2ban/filter.d/web-login.conf`:

```
[Definition]
failregex = ^10\.9\.0\.9 \S+ \S+ \[[^]]*\] "[A-Z]+ [^"]*" 401 .*"(?:[^"]*, )?<ADDR>"$
            ^<HOST> \S+ \S+ \[[^]]*\] "[A-Z]+ [^"]*" 401 
ignoreregex =
```

`/etc/fail2ban/jail.local`, one line added:

```
[web-login]
...
ignoreip = 127.0.0.1/8 10.9.0.9
```

```
$ fail2ban-regex -o ip /var/log/app/access.log web-login | sort | uniq -c | sort -rn
     15 10.9.0.9
     10 203.0.113.66
      8 192.0.2.77
      ...
$ fail2ban-client -t
OK: configuration test is successful
```

`10.9.0.9` still appears, for its health checks, and `ignoreip` covers it. The
attacker and the direct spoofer cross `maxretry`; users with one or two typos
do not.

```
wrongly_banned_ip: 10.9.0.9
real_client_in: X-Forwarded-For
```

**Doing it at the web server instead.** nginx's `real_ip` module does the same
job one layer up: `set_real_ip_from 10.9.0.9; real_ip_header X-Forwarded-For;`
rewrites `$remote_addr` to the forwarded client, only for requests from that
peer, taking the rightmost untrusted entry. Then the stock filter reads the
right address. `set_real_ip_from 0.0.0.0/0` is the same "trust everyone" mistake
as above.

**What about SSH?** This only works because HTTP carries the client address in
the request. sshd has no equivalent: OpenSSH does not accept PROXY protocol, so
behind a TCP proxy `auth.log` records only the proxy's address. The real
options are a layer-4 load balancer that preserves the client source address
(direct server return, or transparent proxying), or doing the rate limiting
and banning at the load balancer, which can see the client.

</details>
