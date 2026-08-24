---
title: "the certificate expired again, and renewing it is somebody's calendar reminder"
---

## The situation

```
$ curl -s https://web.internal/health
curl: (60) SSL certificate problem: certificate has expired
```

Third time this year. The certificate is a file on disk, named in the server
config, and renewing it is a reminder in somebody's calendar that keeps getting
missed — or that fires while that person is on leave.

The interesting part is what else is on this box:

```
$ curl -s https://acme.internal:9443/acme/local/directory | head -4
{
  "newNonce": "https://acme.internal:9443/acme/local/new-nonce",
  "newAccount": "https://acme.internal:9443/acme/local/new-account",
  ...
```

An ACME certificate authority, on the same machine, whose root is already in
this box's trust store. It will issue a certificate to anything that asks
properly. Nothing has been asking.

## Certificates as a thing you install, versus a thing you obtain

The config that broke looks like every TLS config written in the last twenty
years:

```
web.internal {
    tls /etc/ssl/site/web.internal.crt /etc/ssl/site/web.internal.key
    reverse_proxy 172.32.0.11:8080
}
```

Two paths. Somebody generated a CSR, somebody pasted a certificate back, and
the expiry date became an operational fact nobody owns. Every renewal is a
manual sequence performed rarely enough that nobody is fluent in it, under time
pressure, usually while the site is already down.

The alternative is to let the server ask for its own certificate:

```
{
    acme_ca https://acme.internal:9443/acme/local/directory
}

web.internal {
    reverse_proxy 172.32.0.11:8080
}
```

There is no certificate in that config, and that is the whole change. Caddy
knows it serves `web.internal`, so it obtains a certificate for `web.internal`
on first need and renews it in the background long before expiry.

## What ACME actually is

ACME is a protocol for proving you control a name and getting a certificate for
it, without a human in the loop:

1. The client asks the CA's **directory** for the URLs of the other endpoints.
2. It registers an account keypair.
3. It asks for a certificate for a name; the CA responds with a **challenge**.
4. The client proves control — HTTP-01 serves a token at a well-known path on
   port 80, TLS-ALPN-01 answers a special handshake on 443, DNS-01 publishes a
   TXT record.
5. The CA validates, the client sends a CSR, the CA returns the certificate.

Nothing about that is specific to Let's Encrypt. It is an IETF standard
(RFC 8555), and an internal CA that speaks it — as this one does — works with
every ACME client that exists. That is the argument for running one internally
rather than a homegrown script around `openssl`: the clients already exist and
already handle renewal, backoff, and storage.

Two details from this box worth keeping:

- **The directory must be HTTPS.** An ACME client will refuse a plain-HTTP
  directory, and the error it gives is about a scheme mismatch deep in a nonce
  request rather than anything that says "use HTTPS".
- **Trust is a separate problem from issuance.** A certificate from an internal
  CA verifies only on machines whose trust store has that CA's root. Here the
  platform team already put it there. In a real fleet that distribution is the
  actual work; the issuing part is the easy half.

## The twelve-hour certificate

Read what the CA issued:

```
$ echo | openssl s_client -connect web.internal:443 -servername web.internal 2>/dev/null \
    | openssl x509 -noout -dates
notBefore=Aug 23 21:48:29 2026 GMT
notAfter=Aug 24 09:49:29 2026 GMT
```

Twelve hours.

That number is impossible to operate by hand and completely unremarkable when
issuance is automatic — and it is *better*, because a short lifetime bounds the
damage from a leaked key and keeps the renewal path exercised constantly. The
renewal that runs every few hours is the one that works when you need it; the
one that runs annually is a procedure nobody has tested since the last time it
failed.

This is why "automatic HTTPS" is not a convenience feature. It changes what
lifetimes are reasonable, which changes what a stolen key is worth.

## Your objective

1. `curl https://web.internal/health` returns `ok`, verifying with no `-k` and
   no `--cacert`, with a certificate issued by the internal CA.
2. No certificate file named in the config. Nothing on disk should ever need a
   human to replace it again.
3. Renewal has to work: the grader deletes the certificate the server is
   holding, restarts it, and expects a different one to appear without anybody
   editing anything.

Then `/root/answers/acme.md`:

```
acme_directory: <url>
cert_lifetime_hours: <number>
```

## What you're being graded on

**It verifies against the trust store the box already has.** `tls internal` —
Caddy's own built-in CA — also produces working automatic HTTPS and fails here,
because nothing trusts that CA. Issuance and trust are separate, and this check
is the difference.

**The config names no certificate file.** Pointing `acme_ca` at the right place
while leaving the `tls <cert> <key>` line in means the file still wins and
nothing has changed.

**A deleted certificate comes back on its own.** This is the requirement the
whole lesson is about. Anything that got a certificate once by hand — even from
the right CA — fails it.

<details>
<summary>Hint 1 — what is in the config that should not be</summary>

The site block names two files. As long as it does, the server has been told
what certificate to use and will never ask for one.

</details>

<details>
<summary>Hint 2 — pointing Caddy at a CA that is not the public one</summary>

Caddy defaults to Let's Encrypt, which this box cannot reach and which would not
issue for `web.internal` anyway. The global option is `acme_ca`, and it takes
the directory URL — the one that answers with a JSON object full of endpoint
URLs.

```
{
    acme_ca https://acme.internal:9443/acme/local/directory
}
```

</details>

<details>
<summary>Hint 3 — watching it happen</summary>

```
$ journalctl -u caddy-site -f
```

Restart the service and read the exchange: obtaining, challenge, certificate
obtained. If it is retrying, the message says what the CA objected to.

</details>

## What actually happened

A certificate that had to be replaced by a person expired, because a person did
not replace it. The fix was not a better reminder — it was removing the step
that needed one:

```
{
    acme_ca https://acme.internal:9443/acme/local/directory
}

web.internal {
    reverse_proxy 172.32.0.11:8080
}
```

The server now obtains its own certificate, on first use and on every renewal,
from a CA the fleet already trusts. The certificates it gets last twelve hours,
which nobody has to care about, which is the point.

<details>
<summary>Solution</summary>

```bash
$ cat /etc/caddy/site.caddyfile
```

```
{
    admin off
    acme_ca https://acme.internal:9443/acme/local/directory
}

web.internal {
    reverse_proxy 172.32.0.11:8080
}
```

```bash
$ caddy validate --config /etc/caddy/site.caddyfile --adapter caddyfile
$ systemctl restart caddy-site
$ curl -s https://web.internal/health
ok
$ printf 'acme_directory: https://acme.internal:9443/acme/local/directory\ncert_lifetime_hours: 12\n' \
    > /root/answers/acme.md
```

</details>

## Carrying this forward

- **A renewal that needs a human is an outage with a date on it.** The question
  is not who forgot; it is why forgetting was possible.
- **ACME is a standard, not a vendor.** The same client that talks to Let's
  Encrypt talks to an internal CA, which is the cheapest way to get automatic
  certificates for names the public internet cannot validate.
- **Issuance and trust are different problems.** Getting a certificate is
  automatic; getting every client to trust the issuer is distribution work, and
  it is the half that actually takes planning.
- **Short lifetimes are a feature of automation.** Twelve hours is absurd by
  hand and unremarkable automatically, and it bounds what a leaked key is worth.
- **Test renewal by forcing it.** A renewal path that has never run is a
  hypothesis. Delete the certificate, restart, and watch it come back — before
  the day it has to.
