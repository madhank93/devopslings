---
title: "half the egress works, and the other half broke when you fixed it"
---

## The situation

The perimeter went up last month. Nothing on this box reaches the outside world
on its own any more; there is an egress proxy at `http://10.91.0.2:3128` and
everything external is supposed to go through it.

In your shell, the vendor API works and the internal one does not:

```
$ curl -sS -o /dev/null -w '%{http_code}\n' http://api.vendor.example/rates
200
$ curl -sS -o /dev/null -w '%{http_code}\n' http://inventory.corp:8080/stock
502
```

The nightly job calls both, and fails the other way round:

```
$ systemctl start stock-sync.service
$ cat /var/lib/stock-sync/last.txt
vendor=fail(000) internal=ok
```

Same box. Same two URLs. Opposite results, depending on who is asking.

## Read the two failures before touching anything

They are not the same failure and they do not have the same fix.

**`502` is an HTTP response.** Something spoke HTTP to you and said no. A `curl`
that could not connect at all cannot produce a status code, so 502 means the
proxy was reached, accepted the request, and could not do what was asked:

```
$ curl -sS -o /dev/null -w '%{http_code}\n' \
    -x http://10.91.0.2:3128 http://inventory.corp:8080/stock
502
```

That is the proxy failing to reach `inventory.corp`. It sits on the perimeter
with one leg outside; nothing routes from there to the inside, and in a real
network nothing should.

**`000` is not a status at all.** It is `curl`'s placeholder for *no HTTP
response happened*. Strip the proxy out of the environment and the reason is
plain:

```
$ env -u http_proxy -u HTTP_PROXY curl -sS -m4 http://api.vendor.example/rates
curl: (7) Failed to connect to api.vendor.example port 80 after 0 ms:
Could not connect to server
```

That is the perimeter — a route that answers "unreachable" instantly, standing
in for the firewall that would otherwise drop the packet in silence.

So: one caller has the proxy and is using it for everything, including traffic
that must not go through it. The other caller does not have the proxy at all.

## Why the job has a different environment from your shell

```
$ grep -i proxy /etc/environment
http_proxy=http://10.91.0.2:3128
HTTP_PROXY=http://10.91.0.2:3128

$ systemctl show stock-sync.service -p Environment
Environment=
```

`/etc/environment` is read by **PAM**, at login. Every interactive session on
this box gets what is in it, which is why it feels like a system-wide setting.

systemd is not a login session. It is PID 1, it starts services from units, and
it never reads `/etc/environment` — a service's environment comes from its unit
(`Environment=`, `EnvironmentFile=`), from `systemctl set-environment`, or from
nothing at all. That is not an oversight: services start before anyone logs in,
and a daemon whose behaviour depends on a file meant for humans is a daemon that
behaves differently at boot than it does when you test it by hand.

This is the single most common shape of "it works when I run it, it fails from
cron/systemd". The environment is not a property of the box. It is a property of
the process tree, and the two trees never touched.

## NO_PROXY is a list of names, and the matching is fussy

`HTTP_PROXY` says *send everything through here*. `NO_PROXY` is the exception
list, and it is checked against **the host as written in the URL** — before
resolution, not after.

Things worth knowing before you write one:

- **It is matched against the name, not the address.** `NO_PROXY=10.91.1.5` does
  nothing for `http://inventory.corp:8080/`. The two are the same host and only
  one of them is in the URL.
- **Entries are suffix matches.** `corp` matches `inventory.corp`;
  `.corp` matches `inventory.corp` and `a.b.corp`. `*` is not a wildcard in
  `curl`, Go, or Python — a literal `*.corp` matches nothing at all. The one
  wildcard that is widely honoured is `NO_PROXY=*`, meaning *never proxy
  anything*.
- **The port is usually ignored, and sometimes is not.** `curl` matches the host
  and ignores the port unless you write `host:port` explicitly.
- **`localhost` and `127.0.0.1` are not automatic** everywhere. `curl` exempts
  them by default; several libraries do not. Listing them costs nothing.
- **Case and spelling are a minefield.** `curl` reads both `http_proxy` and
  `HTTP_PROXY`, but for the plain-HTTP one lowercase wins by convention. Go
  reads both. Some clients read only one. Setting both spellings is the pragmatic
  answer, and it is what most base images do.

## Your objective

Three things.

1. Make the job work:

   ```
   $ systemctl start stock-sync.service
   $ cat /var/lib/stock-sync/last.txt
   vendor=ok internal=ok
   ```

   `/opt/vendor/stock-sync` is shipped by the vendor and checksummed. **It is not
   where the fix goes.** A proxy setting written inside a job has to be found and
   rewritten in every job, every time the network changes; that is precisely what
   the environment variables exist to avoid.

2. Make a login shell get both right too, with the answer written in
   `/etc/environment` — the box's global environment.

3. Write `/root/answers/proxy.md`, exactly two lines:

   ```
   internal_via_proxy_status: <the status the proxy returns for inventory.corp>
   service_ignores: <the file a systemd service does not read>
   ```

Traffic to `api.vendor.example` must go **through** the proxy, and traffic to
`inventory.corp` must go **around** it. The perimeter — the unreachable route to
`10.91.2.0/24` — is not yours and must still be there at the end.

## What you're being graded on

The job reporting `vendor=ok internal=ok` and a login shell getting 200 from
both. The proxy log showing `api.vendor.example` for each of those runs and
never showing `inventory.corp`. The vendor's script untouched, the perimeter
intact, and both answers.

<details>
<summary>Hint 1 — the proxy keeps a log, and it settles every argument</summary>

```
$ tail -f /var/log/egress-proxy.log
```

One line per request, with the host that was asked for and what happened:

```
2026-08-19T19:00:16 GET http://inventory.corp:8080/stock 502-OSError
2026-08-19T18:56:22 GET http://api.vendor.example/rates 200
```

"Did that go through the proxy" stops being a guess. Watch it while you run each
`curl`, and you will see which requests are arriving that should not be.

</details>

<details>
<summary>Hint 2 — prove the environment, do not assume it</summary>

For the service:

```
$ systemctl show stock-sync.service -p Environment
$ systemctl cat stock-sync.service
```

`systemctl cat` prints the unit and every drop-in that applies to it, in order.
A drop-in is a file at `/etc/systemd/system/<unit>.d/<anything>.conf` holding
just the section you want to add:

```
[Service]
Environment=...
```

`systemctl daemon-reload` after writing one, then start the service again.

For the shell half, the file is `/etc/environment` — one `KEY=value` per line,
no `export`, no shell syntax.

</details>

<details>
<summary>Hint 3 — check your NO_PROXY the way curl does</summary>

```
$ curl -v --proxy http://10.91.0.2:3128 --noproxy inventory.corp \
    http://inventory.corp:8080/stock
```

`-v` says which route a request took: `Connected to 10.91.0.2 (10.91.0.2) port
3128` means it went to the proxy, and `Connected to inventory.corp` means it did
not. `--noproxy` on the command line takes the same syntax `NO_PROXY` does, so
you can test a value before writing it into a file.

</details>

## What actually happened

Nothing was broken. Two configurations were incomplete, in opposite directions:

- `/etc/environment` had `http_proxy` and no `NO_PROXY`, so login shells proxied
  everything, including the internal service the proxy has no route to.
- `stock-sync.service` had neither, because systemd does not read
  `/etc/environment`, so the job went direct into a perimeter that refuses it.

The reason this drags on for days in real life is the shape of the ticket. The
first person adds `HTTP_PROXY` and the outside starts working; the second person
notices the internal calls have started failing and takes it back out; the third
adds it to the one service they were looking at. Every step fixes half and
breaks half, because the pair of variables is a pair and the environment is
per-process.

<details>
<summary>Solution</summary>

The global environment, both halves, both spellings:

```
$ cat >> /etc/environment <<'ENV'
no_proxy=inventory.corp,localhost,127.0.0.1
NO_PROXY=inventory.corp,localhost,127.0.0.1
ENV
```

The service, which will never read that file:

```
$ mkdir -p /etc/systemd/system/stock-sync.service.d
$ cat > /etc/systemd/system/stock-sync.service.d/proxy.conf <<'DROPIN'
[Service]
Environment=http_proxy=http://10.91.0.2:3128
Environment=HTTP_PROXY=http://10.91.0.2:3128
Environment=no_proxy=inventory.corp,localhost,127.0.0.1
Environment=NO_PROXY=inventory.corp,localhost,127.0.0.1
DROPIN
$ systemctl daemon-reload
$ systemctl start stock-sync.service
$ cat /var/lib/stock-sync/last.txt
vendor=ok internal=ok
```

And the log agrees that each request went the way it should:

```
$ tail -2 /var/log/egress-proxy.log
2026-08-19T19:12:44 GET http://api.vendor.example/rates 200
```

One line, not two. The inventory call never reached the proxy.

```
internal_via_proxy_status: 502
service_ignores: /etc/environment
```

</details>

## Carrying this forward

- **`000` is not a status code.** It is "no response". A real status, even 502,
  means something answered — and tells you which hop it was.
- **`HTTP_PROXY` without `NO_PROXY` is half a configuration.** Write both at the
  same time, always, or you will take the outage in the other direction.
- **`NO_PROXY` matches the string in the URL.** Names, not addresses; suffixes,
  not globs. Test it with `curl --noproxy` before you commit it.
- **A service's environment comes from its unit.** `/etc/environment`, `.bashrc`
  and `.profile` are for login sessions. "Works in my shell, fails under
  systemd" is this, most of the time.
- **In containers, the same variables are set at build or run time**, and
  `NO_PROXY` needs to include the service names on the internal network for
  exactly the same reason.

The next lesson leaves the proxy alone and runs the box out of something it has
plenty of: ports.
