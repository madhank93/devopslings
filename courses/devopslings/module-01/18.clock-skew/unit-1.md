---
title: "the certificate is fine and the handshake still fails"
---

## The situation

`ledger-sync` talks to `ledger.internal:8443`, which is running on the same box.
It has stopped being able to:

```
$ systemctl status ledger-sync
     Active: failed (Result: exit-code)

$ journalctl -u ledger-sync -o cat -n 1
ledger-sync: URLError: <urlopen error [SSL: CERTIFICATE_VERIFY_FAILED]
  certificate verify failed: certificate is not yet valid>
```

**Not yet valid.** Not expired — not yet valid. And from your own shell, against
the same URL, with the same CA:

```
$ curl --cacert /etc/ledger/ca.crt https://ledger.internal:8443/status
ledger ok
```

Two clients, one certificate, one endpoint, opposite results.

## Your objectives

| file | answer |
|---|---|
| `/root/answers/cause` | one of `clockskew`, `expiredcert`, `badchain`, `hostname` |

Then make `ledger-sync` complete and write `/srv/ledger/last-sync`.

**Do not weaken the client** — it must keep verifying against
`/etc/ledger/ca.crt`. **Do not reissue the certificate.**

## What you're being graded on

The named cause, a successful sync with verification intact, and — the decisive
one — the time `ledger-sync` itself reports being within two minutes of the
box's clock. A handshake that succeeds while the skew is still there does not
pass.

<details>
<summary>Hint 1 — read the error as a claim about time</summary>

"Certificate is not yet valid" is not a vague TLS complaint. It is a specific
assertion: **the current time is before this certificate's `notBefore`.**

There are exactly two ways that can be true:

1. The certificate genuinely starts in the future.
2. The thing checking it thinks the time is earlier than it is.

Rule out the first, since it takes one command:

```
$ openssl x509 -in /etc/ledger/server.crt -noout -dates
notBefore=Aug  4 03:20:00 2026 GMT
notAfter=Aug  4 03:20:00 2027 GMT

$ date -u
Tue Aug  4 03:24:11 UTC 2026
```

Valid since four minutes ago. So the certificate is fine, and something
checking it disagrees about now.

While you are here, eliminate the other two candidates properly:

```
$ openssl verify -CAfile /etc/ledger/ca.crt /etc/ledger/server.crt
/etc/ledger/server.crt: OK
$ openssl x509 -in /etc/ledger/server.crt -noout -ext subjectAltName
    DNS:ledger.internal
```

Chain good, name good.

</details>

<details>
<summary>Hint 2 — the box's clock is not the client's clock</summary>

`date` tells you what **your shell** thinks the time is. That is not necessarily
what another process on the same box thinks, and this is the assumption worth
breaking.

Ask the service itself. `ledger-sync` records its own view of the time whenever
it succeeds, but it is not succeeding — so run it under the same environment
systemd gives it and see:

```
$ systemctl show ledger-sync.service -p Environment
$ systemctl cat ledger-sync.service
```

`systemctl cat` prints the unit **and every drop-in**, which is where things get
added and forgotten.

</details>

<details>
<summary>Hint 3 — what a drop-in can do to one process</summary>

```
$ systemctl cat ledger-sync.service
# /etc/systemd/system/ledger-sync.service
...
# /etc/systemd/system/ledger-sync.service.d/10-testing.conf
[Service]
Environment=LD_PRELOAD=/usr/lib/aarch64-linux-gnu/faketime/libfaketime.so.1
Environment=FAKETIME=-730d
```

`LD_PRELOAD` loads a library ahead of libc, and `libfaketime` intercepts the
time calls. `FAKETIME=-730d` means every `clock_gettime` this process makes
returns a value two years in the past.

So `ledger-sync` is not wrong about the certificate. From where it is standing,
a certificate issued today genuinely does not become valid for another two
years.

Somebody added this during a date-handling test in June. It is scoped to one
unit, it survives reboots, and it appears nowhere in the box's own clock — which
is why `date`, `timedatectl` and `curl` all look perfectly healthy.

</details>

<details>
<summary>Solution</summary>

```
$ echo clockskew > /root/answers/cause

$ rm /etc/systemd/system/ledger-sync.service.d/10-testing.conf
$ systemctl daemon-reload
$ systemctl start ledger-sync
$ cat /srv/ledger/last-sync
1785813851 ledger ok
```

### Why this is a lesson at all

The reflex when TLS fails is to suspect the certificate, because the certificate
is the thing you can see and the thing that expires. Here every property of the
certificate is correct and the verification is correct too — the client applied
the rules perfectly against a clock that was lying to it.

Three things worth keeping:

1. **Read TLS errors as the specific claims they are.** "Not yet valid",
   "expired", "self-signed certificate in chain", "hostname mismatch" and
   "unknown CA" are five different failures with five different fixes. "TLS is
   broken" is not a diagnosis, and the error text almost always names the
   mechanism if you stop skimming it.

2. **`date` answers for your shell, not for the box.** A process can hold a
   different view of the time — through `LD_PRELOAD` here, and in the real world
   through a container with a skewed host, a VM resumed from a snapshot, a
   hypervisor that lost its paravirtual clock, or an NTP daemon that has never
   once successfully synced. Ask the failing process what time it thinks it is.
   That single question separates "the certificate is wrong" from "the observer
   is wrong" in about ten seconds.

3. **`systemctl cat`, not `cat`.** Drop-ins are invisible if you only read the
   unit file, and they are exactly where debugging leftovers accumulate. The
   same shape appears three times in this module: a hold left behind after an
   incident in `package-held-back`, a reaper written for the wrong resource in
   `inodes-not-bytes`, and a test harness left enabled here. Temporary changes
   are permanent unless something makes them visible.

**A note on how this scenario is built.** The skew is injected with
`libfaketime` rather than by moving the clock, because a container shares the
kernel's wall clock with its host — time namespaces virtualise only
`CLOCK_MONOTONIC` and boottime, never `CLOCK_REALTIME`. Setting the date inside
this box would move it for every container on your machine. The injection is
therefore a simplification, in the same spirit as the latency `chaos-stack`
injects; the diagnostic path — read the error, check the cert, ask the process
what time it thinks it is, find what changed its view — is the real one.

</details>
