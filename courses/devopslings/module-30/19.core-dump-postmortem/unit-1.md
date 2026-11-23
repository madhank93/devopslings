---
title: "one parcel, and the pricing service dies every second"
---

## The situation

`tariffd` prices parcel requests: it picks up each file in
`/var/spool/tariffd/inbox`, writes a price to `done/`, and removes the
request. Since this morning it restarts every second:

```
$ systemctl status tariffd.service
● tariffd.service - Parcel tariff pricing
     Active: activating (auto-restart) (Result: core-dump)
$ systemctl show -p NRestarts tariffd.service
NRestarts=412
$ ls /var/spool/tariffd/inbox
q-1043.req  q-1044.req
```

`Result: core-dump` says the kernel killed it with a signal that would have
written a core. Nothing was written. systemd restarts it, it picks up the same
request, and dies again. The team's plan is to add logging and wait for the
next crash, which is happening once a second and telling nobody anything.

## Getting a core

A core is a snapshot of the process's memory at the moment it died: every
stack, every variable. Two things decide whether one is written and where:

- **The core size limit.** `RLIMIT_CORE` of 0 means no core. Shells often set
  it to 0, and systemd's default for services is 0 too. For a unit:
  `LimitCORE=infinity` in a drop-in (`systemctl edit tariffd.service`).
- **`kernel.core_pattern`.** Where the kernel writes it.
  `cat /proc/sys/kernel/core_pattern`. A plain name like `core` is a file in
  the process's working directory. A pattern starting with `|` pipes the core
  to a program — `systemd-coredump`, `apport` — which then stores it
  wherever it stores things.

This box shares its kernel with the host, and `core_pattern` is one setting
for the whole kernel. Changing it here changes it for every container on the
host. Leave it alone and work with whatever it is. If it is a pipe, the
handler runs on the *host*, outside this box, and the core never arrives
here. Then take the core yourself: run the binary under `gdb`, let it hit the
same input, and `generate-core-file <path>` when it stops on the signal.

## Reading a core

```
gdb /usr/local/bin/tariffd <core>
(gdb) bt
```

`bt` prints the stack at the moment of death, innermost frame `#0` first. The
binary was built with `-g`, so each frame shows its function, arguments and
`file:line`. Frame `#0` is often inside the C library: `strlen` crashed
because it was handed a bad pointer. The bug is in the first frame that is
your code — the one that handed it over. `frame N` selects a frame; `info
locals` and `print` show its variables.

## Your objectives

1. Capture a core of the crash, and write what it shows to
   `/root/answers/core.txt`:

   ```
   core=<path to the core file>
   function=<the tariffd.c function where it crashed>
   line=<its line number>
   ```

2. Fix `/usr/local/src/tariffd/tariffd.c` (`make -C /usr/local/src/tariffd
   install` rebuilds and installs it) so the same request no longer kills
   the service, and the queue behind it moves.

## What you're being graded on

The check confirms `core_pattern` is unchanged, that your core is a core of
`tariffd`, and the frame. Then it replays the request that crashed it, with a
normal request after it: `tariffd` must keep the same PID throughout, price
the normal one, and take the bad one out of the inbox.

<details>
<summary>Hint 1 — no core appeared</summary>

`systemctl show -p LimitCORE tariffd.service`. If it is 0, set
`LimitCORE=infinity` in a drop-in and restart. With `core_pattern` set to
`core`, it lands in the unit's `WorkingDirectory`. With a `|` pattern, use
the gdb route instead: `systemctl stop tariffd`, then
`gdb -batch -ex run -ex 'generate-core-file /var/tmp/tariffd.core' /usr/local/bin/tariffd`.

</details>

<details>
<summary>Hint 2 — what was it given</summary>

In gdb, `frame 1`, then `print region`. Then look at the request that was
being processed: `frame 2`, `print in` (or `print r`), and `cat` that file.
What does `parse()` return for a field that is not there?

</details>

<details>
<summary>Solution</summary>

```
Program terminated with signal SIGSEGV, Segmentation fault.
#0  0x0000ffff8a1b2c40 in __strlen_asimd () from /lib/aarch64-linux-gnu/libc.so.6
#1  0x0000aaaab2c41090 in region_rate (region=0x0) at tariffd.c:28
#2  0x0000aaaab2c41274 in price (name=0x... "q-1043.req") at tariffd.c:67
#3  0x0000aaaab2c41390 in main () at tariffd.c:86
```

```
core=/var/lib/tariffd/core
function=region_rate
line=28
```

`q-1043.req` has no `region=` line. `field()` returns NULL for a missing
field, `parse()` stores it, and `region_rate()` calls `strlen(NULL)`. Every
restart picks the same file up first. Reject it instead of pricing it:

```c
    if (parse(in, &r) != 0)
        return;
    if (!r.region) {
        FILE *e = fopen(out, "w");
        if (e) {
            fprintf(e, "id=%s\nerror=missing region\n", r.id);
            fclose(e);
        }
        unlink(in);
        return;
    }
```

Deleting `q-1043.req` by hand clears today's incident and leaves the next
request with a missing field to do it again.

### Cores in production

- `coredumpctl list` and `coredumpctl gdb` work where `core_pattern` pipes to
  `systemd-coredump`; on Ubuntu, `apport` stores them under `/var/crash`. In
  Kubernetes the pattern is the node's, and the core lands on the node.
- A core contains everything that was in memory: tokens, keys, customer
  data. Treat it as you would a database dump.
- Without `-g` the backtrace has function names but no lines. Ship debug
  symbols separately (`objcopy --only-keep-debug`, Debian's `-dbgsym`
  packages) so the release binary stays small and a core is still readable.

</details>
