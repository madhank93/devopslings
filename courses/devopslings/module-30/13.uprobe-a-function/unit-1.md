---
title: "one function is slow, and the next deploy window is Thursday"
---

## The situation

`pricer` is a small C service: it parses an order, looks up a price, formats
a reply, a few dozen times a second. It is slower than it should be, and
everyone's suspect is `price_lookup()`. The source is in `/opt/pricer`, and the
binary was built with symbols.

The usual move is to wrap `price_lookup()` in timing logs and redeploy. Here
that needs a change window, and the next one is Thursday. It also changes the
thing being measured: a log line inside a hot function costs time, and a
restart throws away whatever state made it slow.

## Your objectives

- Measure `price_lookup()`'s own latency inside the running `pricer` — no
  restart, no rebuild
- Save the bpftrace program as `/root/uprobe.bt`; it must print a histogram
  with `hist()`
- Write `/root/answers/latency.md`:

```
latency-ms: <how long one price_lookup() call takes>
```

## What you're being graded on

- `pricer` is the same process it was at the start: same PID, same start time
- `latency-ms` matches the delay the scenario gave `price_lookup()`
- then the grader changes that delay to one you have not seen, runs your
  `/root/uprobe.bt` for four seconds, and the fullest bucket of its histogram
  has to hold the new delay (read as ns, µs or ms)

Timing the whole request instead of the one function lands in the wrong
bucket.

<details>
<summary>Hint 1 — what can be probed</summary>

```
bpftrace -l 'uprobe:/opt/pricer/pricer:*'
```

A `uprobe` fires when a function is entered; a `uretprobe` when it returns.

</details>

<details>
<summary>Hint 2 — pairing entry with return</summary>

Store `nsecs` keyed by `tid` in the uprobe, subtract in the uretprobe, delete
the key. Divide by 1000 to histogram microseconds.

</details>

<details>
<summary>Hint 3 — reading the answer</summary>

`hist()` buckets are powers of two. For a single number, add `avg()` of the
same value next to it.

</details>

## Uprobes

A uprobe is a breakpoint the kernel plants in a user-space binary. The kernel
replaces the first instruction of the function with a trap; when any process
running that binary hits it, the kernel runs your BPF program and then lets
the function carry on. Nothing is rebuilt and nothing restarts. A uretprobe
does the same at return, by swapping the return address on the stack for a
trampoline.

The probe needs a symbol to attach to, which a binary built with `-g` or just
not stripped has:

```
$ bpftrace -l 'uprobe:/opt/pricer/pricer:*'
uprobe:/opt/pricer/pricer:format_reply
uprobe:/opt/pricer/pricer:handle_request
uprobe:/opt/pricer/pricer:main
uprobe:/opt/pricer/pricer:parse_order
uprobe:/opt/pricer/pricer:price_lookup
```

`noinline` in the source is what keeps these as real functions. An
optimising compiler is free to inline a small static function into its
caller, and an inlined function has no entry to probe.

## Timing one function

```
uprobe:/opt/pricer/pricer:price_lookup { @start[tid] = nsecs; }

uretprobe:/opt/pricer/pricer:price_lookup /@start[tid]/
{
  @us = hist((nsecs - @start[tid]) / 1000);
  @avg_us = avg((nsecs - @start[tid]) / 1000);
  delete(@start[tid]);
}

END { clear(@start); }
```

Keyed by `tid`, the start time belongs to the thread that made the call, so
two threads in the function at once do not overwrite each other. The
`/@start[tid]/` filter skips returns whose entry was missed because the
program attached mid-call.

One caveat for this box: it is a container, and bpftrace here cannot resolve
IDs in the box's PID namespace (it warns `get_ns_current_pid_tgid, retcode:
-22`), so `tid` does not tell threads apart. `pricer` has one thread, so the
program above still times it correctly; on a threaded target inside a
container, key on something the kernel reports directly, such as
`curtask->pid`.

```
$ bpftrace /root/uprobe.bt
Attaching 3 probes...
^C
@avg_us: 12081

@us:
[8K, 16K)            163 |@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@|
```

Every call lands in one bucket, and the average says where in it.

Probing `handle_request` instead answers a different question. It includes
`parse_order` (9 ms) and `format_reply` (under 1 ms), so it lands one or two
buckets higher — a believable number for the wrong function. Look at the
source to see what a function you probe actually calls.

## Why C

The target here is C on purpose. A uretprobe works by rewriting the return
address on the thread's stack. Go moves goroutine stacks when they grow, and a
stack copied with the trampoline address in it can crash the process. For Go,
probe the entry only, or use a tool that knows Go's calling convention.

## Checking yourself

```
bpftrace /root/uprobe.bt     # Ctrl-C after a few seconds
systemctl show -P MainPID pricer
```

The PID should be the one `pricer` had when the lesson started.

<details>
<summary>Solution</summary>

`/root/uprobe.bt`:

```
uprobe:/opt/pricer/pricer:price_lookup { @start[tid] = nsecs; }
uretprobe:/opt/pricer/pricer:price_lookup /@start[tid]/
{
  @us = hist((nsecs - @start[tid]) / 1000);
  @avg_us = avg((nsecs - @start[tid]) / 1000);
  delete(@start[tid]);
}
END { clear(@start); }
```

Run it for a few seconds and convert `@avg_us` to milliseconds:

```
latency-ms: 12
```

(The number is whatever delay your scenario drew: 3, 6, 12 or 24 ms.)

</details>
