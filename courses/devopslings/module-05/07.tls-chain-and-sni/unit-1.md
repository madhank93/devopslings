---
title: "curl -k works, and that is the whole problem"
---

## The situation

The deploy step has not published a build since Tuesday. It runs
`/usr/local/bin/publish`, which is four lines of `curl`, and it says:

```
curl: (60) SSL: no alternative certificate subject name matches
target ipv4 address '172.31.0.10'
```

Reaching the same gateway by name fails too, and says something else entirely:

```
$ curl https://artifacts.corp:8443/
curl: (60) SSL certificate problem: unable to get local issuer certificate
```

One listener, two error messages. Meanwhile everything anyone has checked says
the certificate is fine:

```
$ openssl x509 -in /opt/pki/artifacts.corp.crt -noout -subject -enddate
subject=O=Corp, CN=artifacts.corp
notAfter=Nov 21 15:08:51 2028 GMT

$ curl -sk https://artifacts.corp:8443/
vhost-gateway-2026

$ curl -s https://internal-tools.corp:8443/
vhost-gateway-2026
```

Not expired. Right name. `curl -k` works. And `internal-tools.corp`, on the same
box, the same port, the same CA, verifies without complaint.

The suggestion already in the ticket is to add the issuing CA to the trust store
on the CI runners. It would work, on the CI runners, and it is the wrong fix — it
is a note to the whole organisation saying *every client that ever talks to this
gateway must first be modified*.

## Two errors are two faults

The first instinct is to treat the two messages as one problem seen twice. They
are not. Read them again:

- **`unable to get local issuer certificate`** — the client got a certificate it
  cannot build a path from. This is about *trust*.
- **`no alternative certificate subject name matches`** — the client got a
  certificate for something else. This is about *identity*.

A certificate has to survive both checks. It has to chain to something the client
already trusts, and the name on it has to be the name the client asked for.
Different failures, different fixes, and here they are stacked so that fixing
either one alone leaves the deploy step broken.

## Fault one: the chain

Ask the gateway what it actually sends, for each of the two sites:

```
$ echo | openssl s_client -connect 172.31.0.10:8443 -servername artifacts.corp
Certificate chain
 0 s:O=Corp, CN=artifacts.corp
   i:O=Corp, CN=Corp Issuing CA 2026
...
Verify return code: 21 (unable to verify the first certificate)
```

```
$ echo | openssl s_client -connect 172.31.0.10:8443 -servername internal-tools.corp
Certificate chain
 0 s:O=Corp, CN=internal-tools.corp
   i:O=Corp, CN=Corp Issuing CA 2026
 1 s:O=Corp, CN=Corp Issuing CA 2026
   i:O=Corp, CN=Corp Root CA 2026
...
Verify return code: 0 (ok)
```

That is the whole diagnosis, in the numbers down the left. `s:` is the subject —
who the certificate is for. `i:` is the issuer — who signed it. The working site
sends **two** certificates. The broken one sends **one**.

Both leaves say the same thing about themselves: *I was signed by Corp Issuing CA
2026*. Neither of them carries the proof. The trust store on this box has one
Corp certificate in it:

```
$ ls /usr/local/share/ca-certificates/
corp-root.crt
```

So a client that gets only the leaf is holding a signature by *Corp Issuing CA
2026*, a trust anchor called *Corp Root CA 2026*, and nothing to connect them
with. It cannot verify what it cannot see. That is error 20, promoted to error 21
because the first certificate is where the path ran out.

**A server must send every certificate between its leaf and a root, and the root
is the one it does not need to send.** Roots live in trust stores. Intermediates
live on the server, and this is the single most common TLS misconfiguration in
existence, because *it does not fail everywhere*. Browsers hide it: having seen
the intermediate once from another site, they cache it and fill in the gap
themselves. Some even fetch it from the URL in the certificate. Your Go binary,
your Java service and your `curl` do neither. That is why "it works in Chrome"
and "the client library is broken" arrive in the same ticket.

## Fault two: the name

Fix the chain and the deploy step still fails, with the other message. Ask the
gateway what it serves when nobody tells it which site they want:

```
$ echo | openssl s_client -connect 172.31.0.10:8443 -noservername 2>/dev/null \
  | openssl x509 -noout -subject
subject=O=Corp, CN=internal-tools.corp
```

Two sites share one IP address and one port. The only thing that separates them
is **SNI** — Server Name Indication, a field in the ClientHello where the client
writes the hostname it is trying to reach, *before* any certificate is chosen. It
exists because the server has to pick a certificate at handshake time, and the
`Host:` header that would have said which site is wanted is inside the encryption
that has not happened yet.

If no name arrives, the listener has to serve something. What it serves is the
default vhost — here, another team's site.

Now look at what `publish` asks for:

```
curl -sS --max-time 15 --data-binary @/root/build.tar.gz \
     https://172.31.0.10:8443/publish
```

An IP address in the URL. **A URL with an IP literal in it sends no SNI at all** —
not the address, not anything. SNI carries hostnames, and an IP address is not
one, so the field is simply omitted. The gateway hears nothing, serves the
default vhost's certificate, and `curl` reports the truthful and thoroughly
confusing thing: the certificate it was handed does not name `172.31.0.10`.

The gateway logs the name it was given for every handshake, which makes this
visible from the other side:

```
$ tail -3 /var/log/vhosts.log
2026-08-19T15:08:53 sni=artifacts.corp
2026-08-19T15:08:53 sni=internal-tools.corp
2026-08-19T15:09:41 sni=-
```

`sni=-` is the deploy step. It never said what it wanted.

## Your objective

Three things.

1. Make `https://artifacts.corp:8443/` verify against the system trust store from
   an unmodified client. **The trust store may not gain a new anchor.** The root
   is already in it and is the only thing that belongs there.

2. Make `/usr/local/bin/publish` succeed with verification switched on:

   ```
   $ /usr/local/bin/publish
   published bytes=65536
   ```

   `-k` and `--insecure` are not fixes. They are the bug report.

3. Write `/root/answers/tls.md`, exactly two lines:

   ```
   missing_link: <the certificate the gateway was not sending>
   no_sni_vhost: <the site that answers when no server name is sent>
   ```

`internal-tools.corp` is another team's site on that same listener, and it is the
**default** vhost. It was working before you started, and it has to be the
default, and working, when you are finished.

## What you're being graded on

That `artifacts.corp` verifies for a client that trusts only the root — the view
every laptop and CI runner elsewhere on the network has, and the one thing
editing this box's trust store cannot fake. That `publish` completes with
verification on and the gateway logs `sni=artifacts.corp` when it does. That
`internal-tools.corp` still verifies and is still the default. And both answers.

<details>
<summary>Hint 1 — ask the server, not the file</summary>

`openssl x509` reads a file on disk. It tells you nothing about what is on the
wire. `openssl s_client` is the client's view:

```
$ echo | openssl s_client -connect 172.31.0.10:8443 -servername artifacts.corp
```

Read the `Certificate chain` block at the top — one indented `s:`/`i:` pair per
certificate the server sent. Run it against `internal-tools.corp` too, and count
the entries in each.

`-servername` is what puts the name in the ClientHello. `-noservername` leaves it
out, which is how you ask what a client dialling an IP address gets.

</details>

<details>
<summary>Hint 2 — verify the way a stranger does</summary>

Verifying against this box's trust store proves only that this box is happy.
Point `openssl` at the root alone and you are asking the question every other
client asks:

```
$ echo | openssl s_client -connect 172.31.0.10:8443 -servername artifacts.corp \
    -CAfile /opt/pki/root.crt -verify_return_error
```

`Verify return code: 0 (ok)` there means it works everywhere. Anything else means
it works only where somebody has been fiddling with the trust store.

The same question about the files on disk:

```
$ openssl verify -CAfile /opt/pki/root.crt /opt/pki/artifacts.corp.crt
$ openssl verify -CAfile /opt/pki/root.crt -untrusted /opt/pki/intermediate.crt \
    /opt/pki/artifacts.corp.crt
```

The second one succeeds. `-untrusted` is exactly the role the server's chain
file plays: *here is the path, you still have to trust the end of it.*

</details>

<details>
<summary>Hint 3 — where the gateway keeps its certificates</summary>

```
$ cat /etc/vhosts/vhosts.json
$ ls /opt/pki/
```

One site is pointed at a file named for the leaf. The other is pointed at a file
whose name ends in `.chain.crt`. Look at how many certificates are in each:

```
$ grep -c 'BEGIN CERTIFICATE' /opt/pki/artifacts.corp.crt
$ grep -c 'BEGIN CERTIFICATE' /opt/pki/internal-tools.corp.chain.crt
```

Order matters when you build one: leaf first, then each issuer above it. The
gateway reads its config at startup, so `systemctl restart vhosts` after.

</details>

<details>
<summary>Hint 4 — the second fault is one word in a URL</summary>

Making `artifacts.corp` the default vhost would make `publish` work. Do not: the
default is somebody else's, and it would hand the artifacts certificate to every
stray client that ever dials this box by address. Fix the client instead — it is
already in `/etc/hosts`.

</details>

## Why the intermediate gets left out

Nobody omits a chain on purpose. It happens because **the server is the one place
the mistake is invisible**:

- The CA emailed three files — `cert.pem`, `chain.pem`, `fullchain.pem` — and
  whoever deployed it picked the one whose name matched the config key
  `ssl_certificate`. It is the wrong one. nginx wants the fullchain there;
  Apache historically had a separate `SSLCertificateChainFile`; the split is a
  standing trap.
- The renewal script rewrote the leaf and left the chain file it was concatenated
  from untouched.
- It was tested from a laptop whose browser had cached that intermediate a year
  ago, so the deploy looked clean.
- The intermediate was rotated by the CA. The old one is still on the server, no
  longer signs the new leaf, and the error is identical.

And the failure is always reported as a *client* problem, because the client is
where it shows up. "Works in the browser, fails in Java" is this bug most of the
time. The rest of the time it is a client whose trust store predates the root —
which is the same shape of error and the opposite fix.

## What actually happened

Two independent things, one ticket.

The gateway was configured to serve `artifacts.corp` from a file holding the leaf
and nothing else:

```
"artifacts.corp": {
  "cert": "/opt/pki/artifacts.corp.crt",     # one certificate
  ...
"internal-tools.corp": {
  "cert": "/opt/pki/internal-tools.corp.chain.crt",   # two
```

And the deploy script named the gateway by address, in a URL, which sends no
server name and gets the default vhost's certificate.

The two faults masked each other. With the chain broken, everyone saw error 20
and started arguing about trust stores. With the chain fixed, the error changes
to a name mismatch and looks like a *new* problem — which is why fixing TLS one
error message at a time feels like whack-a-mole and reading the handshake once
does not.

<details>
<summary>Solution</summary>

Build the chain file — leaf first, issuer after — and point the vhost at it:

```
$ cat /opt/pki/artifacts.corp.crt /opt/pki/intermediate.crt \
    > /opt/pki/artifacts.corp.chain.crt

$ jq '.sites."artifacts.corp".cert = "/opt/pki/artifacts.corp.chain.crt"' \
    /etc/vhosts/vhosts.json > /tmp/v.json && mv /tmp/v.json /etc/vhosts/vhosts.json

$ systemctl restart vhosts
```

The gateway now sends both, and it verifies for a client holding only the root:

```
$ echo | openssl s_client -connect 172.31.0.10:8443 -servername artifacts.corp \
    -CAfile /opt/pki/root.crt 2>&1 | grep -E '^ [0-9] s:|Verify return'
 0 s:O=Corp, CN=artifacts.corp
 1 s:O=Corp, CN=Corp Issuing CA 2026
    Verify return code: 0 (ok)
```

Then give the client a name to send:

```
$ sed -i 's#https://[0-9.]*:8443/publish#https://artifacts.corp:8443/publish#' \
    /usr/local/bin/publish

$ /usr/local/bin/publish
published bytes=65536

$ tail -1 /var/log/vhosts.log
2026-08-19T15:20:04 sni=artifacts.corp
```

```
missing_link: Corp Issuing CA 2026
no_sni_vhost: internal-tools.corp
```

</details>

## Carrying this forward

- **`curl -k` working is a diagnosis, not a workaround.** It says the transport
  is fine and the failure is in verification — trust, name, or validity. Use it
  to split the problem, then put it away.
- **Test the chain from outside your own trust store.** `-CAfile <root>` and
  nothing else. A server that verifies only on the box that deployed it is a
  server that verifies nowhere.
- **`ssl_certificate` wants the fullchain.** Leaf first, intermediates after, root
  never. If you remember one line from this lesson, that is the one.
- **An IP address in an HTTPS URL sends no SNI.** On any listener hosting more
  than one site, that means somebody else's certificate — and the error will
  accuse the certificate, not the URL.
- **Read the two questions separately.** Does it chain? Does the name match? Every
  TLS error is one of those two, plus expiry.

The next lesson keeps the certificate valid and the name right, and puts a proxy
in between — where the traffic that must go through it and the traffic that must
not are separated by one environment variable nobody set.
