---
title: "one request, three steps, and only one of them is broken"
---

## The situation

Three tickets came in this morning. All three say the same thing.

```
alpha.internal   — "connection failed"
bravo.internal   — "connection failed"
charlie.internal — "connection failed"
```

They were filed by the same person, from the same laptop, running the same
command against three different services. Three services do not usually break at
the same moment, and these did not: they were broken all along in three
different places, and one sentence flattened all three into the same report.

The sentence is not the reporter's fault. `curl` says something short and
unhelpful for most of these, and "connection failed" is a fair paraphrase of all
of them. It is also useless, because the three failures have nothing in common
and no shared fix.

## One request is three steps

Before any HTTP is spoken, this has to happen:

1. **Resolve.** The name becomes an address. No packet has been sent to the
   service yet — the packets so far went to a *resolver*, which is a different
   machine doing a different job.
2. **Connect.** A TCP connection is opened to that address and port. Still no
   HTTP. This is a three-packet handshake and it either completes, is refused,
   or goes unanswered.
3. **Request.** Now the request is written into the open connection, and a
   response comes back. This is the first moment anything HTTP exists.

Each step has its own tool, and the tools are worth keeping separate:

```
$ dig <name>                  # step 1 only
$ nc -vz <name> <port>        # step 2 only — connect, then hang up
$ curl -v http://<name>:<port>/   # all three, verbosely
```

`curl` alone does all three and reports the first one that failed. That is
convenient and it is why the three tickets look identical — you are reading a
summary, not a diagnosis. Running the steps separately, in order, is how you
find out which one it was.

## Your objective

Run all three probes against all three services and write down what each one
did. Nothing here needs repairing — leave the services exactly as you found
them.

Write `/root/answers/request.md`:

```
alpha:   resolves=<yes|no> connects=<yes|no|na> http=<code|na> step=<resolve|connect|request>
bravo:   resolves=<yes|no> connects=<yes|no|na> http=<code|na> step=<resolve|connect|request>
charlie: resolves=<yes|no> connects=<yes|no|na> http=<code|na> step=<resolve|connect|request>
```

`na` is for a step that never happened because an earlier one failed. If a name
does not resolve there is no address, so there was no connection attempt to
report — that is `na`, not `no`. `no` means it was attempted and it failed.

Each service fails at exactly one step, and each fails at a different one.

## What you're being graded on

All four fields correct for all three services. `step=` has to agree with the
other three fields — the broken step is the first one that did not succeed.

<details>
<summary>Hint 1 — read dig's header, not just its output</summary>

`dig <name>` prints a lot. The line that answers the question is in the header:

```
;; ->>HEADER<<- opcode: QUERY, status: NOERROR, id: 12345
```

`status: NOERROR` with an answer section means the name resolved. `status:
NXDOMAIN` means the resolver is certain the name does not exist. Those are
different from *no reply at all*, which shows up as `connection timed out; no
servers could be reached`.

`dig +short` hides all of it. It prints nothing for NXDOMAIN, nothing for a
timeout, and nothing for a name that exists with no A record — three very
different situations that look identical.

</details>

<details>
<summary>Hint 2 — refused is not timed out</summary>

```
$ nc -vz bravo.internal 8080
```

Watch how long it takes as much as what it says. There are two failures here and
telling them apart is most of network debugging:

- **Instant refusal.** The host is up and reachable. Its kernel replied with a
  RST, because nothing is listening on that port. Something answered you.
- **Nothing, for a long time.** No reply at all. The packet was dropped, by a
  firewall or a routing black hole, or the host is not there.

Both are "connect failed". Only one of them means the machine is unreachable.

</details>

<details>
<summary>Hint 3 — a response is not a success</summary>

```
$ curl -v http://charlie.internal:8080/
```

Read the whole exchange. `Trying 10.70.0.7:8080...` then `Connected to` means
steps 1 and 2 both succeeded. Then look at the status line that comes back.

A 5xx is a *response*. The name resolved, the connection opened, the request was
written, and the server answered — badly, but it answered. That is a failure at
step 3, and nothing in the network is wrong.

`curl` exits 0 for a 503 by default, which is why it can look like "nothing
happened". `curl -w '%{http_code}'` or `curl -f` makes it say so.

</details>

## What was actually wrong

**alpha** — the name does not exist. The resolver is authoritative for
`.internal`, so it answers NXDOMAIN immediately rather than forwarding the query
somewhere. The service may be running perfectly on some address; nobody can tell,
because nothing ever asked it. The fix for this lives in DNS and nowhere else.

**bravo** — the name resolves to `10.70.0.6`, the host is up, and nothing is
listening on 8080. The RST comes back in under a millisecond. The fix is on the
service: it is not running, or it is bound somewhere else. Firewalls do not
usually produce this, which is exactly why the instant refusal is such a useful
signal — it rules out a whole category of cause in one probe.

**charlie** — everything worked and the application said no. HTTP 503, with a
`Retry-After` header, which is a service telling you deliberately that it cannot
serve right now. This ticket does not belong to the network team at all.

Three services, three teams, one sentence describing all of them.

<details>
<summary>Solution</summary>

```
$ dig alpha.internal                 # status: NXDOMAIN
$ dig bravo.internal +short          # 10.70.0.6
$ dig charlie.internal +short        # 10.70.0.7

$ nc -vz bravo.internal 8080         # Connection refused, immediately
$ nc -vz charlie.internal 8080       # succeeded!

$ curl -s -o /dev/null -w '%{http_code}\n' http://charlie.internal:8080/
503
```

```
alpha:   resolves=no  connects=na  http=na  step=resolve
bravo:   resolves=yes connects=no  http=na  step=connect
charlie: resolves=yes connects=yes http=503 step=request
```

</details>

## Carrying this forward

"The network is down" is a conclusion, and it is almost never the first thing you
are entitled to. Three probes, in order, will tell you which third of the problem
you actually have, and two of those thirds are not the network.

Keep the decomposition. Every remaining lesson in this module is a failure at one
of these three steps, taught in more detail:

- resolve — search domains and `ndots`, and why `dig` succeeds where the
  application fails
- connect — bound to the wrong interface, dropped versus rejected, ephemeral
  ports running out
- request — certificate chains, SNI, proxies, and the MTU black hole that only
  breaks big requests

When you can say which step, you already know which of those to read.
