---
title: "ten seconds of nothing, then it is fine"
---

## The situation

`fx-rates` caches currency rates for the checkout. It reads two lines of
config, resolves the rates feed's address, and starts listening. On this box
that takes ten seconds:

```
$ systemctl restart fx-rates.service; time curl --retry 20 --retry-connrefused -s 127.0.0.1:8090/
{"ready": true, "feed": "10.20.0.15"}
real    0m10.08s
```

Once it is up, it is fast. The ticket asks for `TimeoutStartSec=60` "because
the service is slow to initialise". The service does almost nothing during
those ten seconds: `top` shows it at 0% CPU.

## Time per system call

Last lesson used strace to see *which* call failed. Here nothing fails; the
question is where the wall-clock time goes. Two options answer it:

- `-T` appends the time spent inside each call: `poll(...) = 0 (Timeout) <5.005>`.
- `-c` prints a summary table per syscall when the program exits; add `-w`
  to count wall time instead of CPU time, which is what a wait costs.

Trace the service from its first instruction by running its command line
under strace, as the unit would:

```
systemctl stop fx-rates.service
strace -f -T -e trace=network,poll,ppoll -o /tmp/fx.trace /usr/local/bin/fx-rates &
sleep 12; kill %1
grep -E '<[0-9]+\.[0-9]+>$' /tmp/fx.trace | sort -t'<' -k2 -rn | head
```

A long call is only half the answer. The lines just before it say what it was
waiting *for*: an address in a `connect` or `sendto`, a file descriptor, a
port.

## How a name becomes an address

`getaddrinfo()` asks the sources listed on the `hosts:` line of
`/etc/nsswitch.conf`, in order: `files` is `/etc/hosts`, `dns` is the
nameservers in `/etc/resolv.conf`. A nameserver that does not answer is not an
error: the resolver waits `timeout` seconds (default 5), tries again
`attempts` times (default 2), and only then moves on to the next source.

## Your objectives

1. Write what startup waits on to `/root/answers/slow-startup.txt`:

   ```
   nameserver=<the address it waits on>
   timeout_seconds=<how long each wait lasts>
   ```

2. Fix the resolver so that `fx-rates` answers within a second of a restart.
   The decommissioned nameserver stays decommissioned: leave its route alone.

## What you're being graded on

The check reads your answer, times a lookup of `rates-feed.internal`, then
restarts `fx-rates` and times its first answer: it must be under one second,
with the feed resolved to its real address. The service and its config must be
unchanged — every program on this box resolves names the same way. A zero
resolver timeout does not pass: it gives up on nameservers that work, too.

<details>
<summary>Hint 1 — what the long calls are waiting for</summary>

Look at the `sendto` or `connect` just before each long `poll`: port 53 is
DNS. Then look at what that address is in `/etc/resolv.conf`, and whether
anything at that address ever answers.

</details>

<details>
<summary>Hint 2 — the answer was on the box all along</summary>

`grep rates-feed /etc/hosts`. The resolver gets there eventually; ten seconds
later. Read the `hosts:` line of `/etc/nsswitch.conf`.

`/etc/resolv.conf` and `/etc/hosts` are bind-mounted into this container, so
`sed -i` cannot replace them (it writes a new file and renames it). Edit them
in place: `cat new > /etc/resolv.conf`.

</details>

<details>
<summary>Solution</summary>

```
connect(3, {sa_family=AF_INET, sin_port=htons(53), sin_addr=inet_addr("10.53.0.53")}, 16) = 0 <0.000021>
sendmmsg(3, [...], 2, MSG_NOSIGNAL) = 2 <0.000046>
poll([{fd=3, events=POLLIN}], 1, 5000) = 0 (Timeout) <5.005112>
...
poll([{fd=3, events=POLLIN}], 1, 5000) = 0 (Timeout) <5.005034>
```

```
nameserver=10.53.0.53
timeout_seconds=5
```

`/etc/nsswitch.conf` has `hosts: dns files`, so every lookup asks DNS first,
and the only nameserver in `resolv.conf` was retired with its network: each
query waits 5 s, twice, and then `/etc/hosts` answers. Ask the local file
first, and stop listing a server that no longer exists:

```
sed 's/^hosts:.*/hosts:          files dns/' /etc/nsswitch.conf > /tmp/ns && cat /tmp/ns > /etc/nsswitch.conf
printf 'nameserver 127.0.0.11\n' > /etc/resolv.conf     # Docker's resolver, the box's original
```

Either change alone brings startup under a second. `options timeout:1`
does not: it cuts each wait to a second and still waits, on every lookup, for
every program on the box.

### strace at startup

- Trace the *command*, not the running PID, when the problem is at startup.
  `strace -p` attaches to a process that has already done its slow part.
- `-e trace=network` cuts a trace to the calls that talk to sockets; `%file`,
  `%process` and `%desc` are the other useful groups.
- A slow `connect()` to port 53, 389 or 88 is a resolver, LDAP or Kerberos
  timeout; they look identical and are found the same way.

</details>
