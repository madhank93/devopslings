---
title: "900 ms requests from a service at 5% CPU"
---

## The situation

`quotes` answers currency quotes on `127.0.0.1:8096`. Its source is in
`/opt/quotes`. Requests take anything up to 900 ms, and the process sits at a
few percent of one CPU:

```
$ for i in 1 2 3 4 5; do curl -s -o /dev/null -w '%{time_total}\n' 127.0.0.1:8096/; done
0.611
0.004
0.873
0.252
0.788
$ top -b -n1 -p $(pgrep -x quotes) | tail -1
  812 root      20   0   ...   S   0.7   0.0   0:00.31 quotes
```

The reflex from module 20's `flame-graph` is to profile it. An on-CPU profile
samples what the CPU is doing, and the CPU is doing almost nothing for this
process: a flame graph of it is a handful of samples in `write` and `accept`,
none of which add up to 900 ms. The time is not spent running. It is spent
waiting, and a CPU profiler does not see a thread that is not on a CPU.

## Your objectives

- Find what `quotes`' requests wait on, and who makes them wait, from where
  its threads spend time *off* the CPU
- Fix the code so requests stop waiting, keeping the rates refreshing from
  `rates-feed` as they do now. `rates-feed` stands in for a remote service: it
  is not yours to change
- Write `/root/answers/offcpu.md`:

```
waits-on: <what a request blocks on, and who holds it>
```

Rebuild with `make -C /opt/quotes && systemctl restart quotes`.

## What you're being graded on

- `waits-on` names the lock and what holds it
- the grader times requests for five seconds: the slowest is under **300 ms**
- over the same five seconds `rates-feed` is still fetched, and `quotes`
  returns at least three different rate versions — removing the refresh
  removes the wait and the data with it
- requests still take a lock before they read the rates

<details>
<summary>Hint 1 — the tool</summary>

`offcputime` runs here but cannot name your functions (see *Off-CPU time
inside a container* below). The same measurement as a bpftrace script:

```
bpftrace -e '
tracepoint:sched:sched_switch /args.prev_comm == "quotes" || args.prev_comm == "rates-refresh"/ {
  @t[args.prev_pid] = nsecs; @s[args.prev_pid] = ustack(6); }
tracepoint:sched:sched_switch /@t[args.next_pid]/ {
  @offcpu_ms[args.next_comm, @s[args.next_pid]] = sum((nsecs - @t[args.next_pid]) / 1000000);
  delete(@t[args.next_pid]); }
END { clear(@t); clear(@s); }'
```

Send it requests while it runs, then Ctrl-C.

</details>

<details>
<summary>Hint 2 — two stacks, one story</summary>

Two threads block for a long time. One is a request, one is not. Look at what
each was doing in `quotes.c` when it went to sleep.

</details>

<details>
<summary>Hint 3 — the shape of the fix</summary>

A slow operation and a lock that requests need should not overlap. Do the slow
part with a private buffer, then take the lock only to swap the result in.

</details>

## Off-CPU time

A thread is either on a CPU or not. When it is not, it went to sleep in the
kernel — on a lock, a socket, a disk read, a timer — and the scheduler
switched to something else. `sched_switch` fires at that moment with the
outgoing thread still current, so a probe there can take its user stack and a
timestamp. When the same thread is switched back in, the difference is how
long it spent off the CPU on that stack. `offcputime` from BCC/libbpf-tools
does exactly this; the script in Hint 1 is the same idea in six lines:

```
@offcpu_ms[quotes,
        __pthread_mutex_lock+264
        handle_quote+24
        main+252
        __libc_start_main+156
]: 4497
@offcpu_ms[rates-refresh,
        fetch_rates+244
        refresh_rates+64
]: 4506
```

Each entry is a thread name and the call chain it went to sleep in, innermost
frame first, with the milliseconds it spent blocked there during the trace.
The frames without names are inside libc's futex and syscall wrappers.

The first entry is the request path. `handle_quote` called
`pthread_mutex_lock`, the mutex was taken, and glibc parked the thread on a
futex for most of the trace. The second is the other thread: `refresh_rates`
sits inside `fetch_rates`, waiting for the feed's 900 ms answer. Put the two next to the source:

```c
pthread_mutex_lock(&rates_lock);
fetch_rates(rates, sizeof rates);   /* 900 ms on the network */
version++;
pthread_mutex_unlock(&rates_lock);
```

The refresher holds `rates_lock` for the whole network round trip, and every
request needs that lock to read `rates`. A request that arrives during a fetch
waits for the rest of it: anything from zero to 900 ms, depending on when it
lands. Neither thread uses CPU while it waits, which is why `top` said
nothing.

Some things that look like fixes and are not:

- **Delete the refresh.** Requests become instant and the rates never change
  again.
- **Refresh less often.** The average improves, and every request that lands
  during a fetch still waits up to 900 ms.
- **Drop the lock from `handle_quote`.** The wait goes away and `snprintf`
  reads a buffer that another thread is writing into.

The lock exists to protect a 128-byte copy; it does not need to cover the
network.

## Off-CPU time inside a container

`offcputime -p $(pgrep -x quotes)` prints nothing in this box, and without
`-p` its user frames come back as `[unknown]` with `failed to get syms`. The
libbpf tools read PIDs straight from the kernel, which knows a process by its
PID in the *host* namespace, where `quotes` is not 812. The filter compares the wrong numbers, and symbol lookup opens
`/proc/<host PID>/maps`, which does not exist inside the container. bpftrace
and `perf` translate PIDs into the caller's namespace and resolve stacks
fine. On a real host, or a container started with `--pid=host`, `offcputime`
works as documented.

## Off-CPU with a profiler

The same view exists in continuous profilers as a *wall-clock* profile:
Pyroscope's Python SDK takes `oncpu=False` and samples threads whether or not
they are running, so blocked frames show up with their wall time. It is the
first thing to switch on when a service is slow and idle at once.

## Checking yourself

```
for i in $(seq 20); do curl -s -o /dev/null -w '%{time_total}\n' 127.0.0.1:8096/; done | sort -n | tail -n 1
for i in 1 2 3; do curl -s 127.0.0.1:8096/; echo; sleep 1; done
```

The slowest should be a few milliseconds, and `version=` should still climb
about once a second.

<details>
<summary>Solution</summary>

In `refresh_rates`:

```c
for (;;) {
    char fresh[sizeof rates];
    if (fetch_rates(fresh, sizeof fresh) == 0) {
        pthread_mutex_lock(&rates_lock);
        memcpy(rates, fresh, sizeof rates);
        version++;
        pthread_mutex_unlock(&rates_lock);
    }
    usleep(50000);
}
```

```
make -C /opt/quotes && systemctl restart quotes
```

```
waits-on: rates_lock in handle_quote, held by the rates-refresh thread across fetch_rates' 900 ms round trip to the feed
```

</details>
