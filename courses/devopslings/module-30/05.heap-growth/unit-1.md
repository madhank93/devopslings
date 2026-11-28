---
title: "RSS only ever goes up"
---

## The situation

`session-cache` answers session lookups from a fixed table of 3000 sessions.
Its memory graph is a ramp: in production it gains about 40 MB an hour across
a soak and never gives any back. On this box the traffic is compressed, so the
same ramp takes minutes:

```
$ pid=$(systemctl show -p MainPID --value session-cache.service)
$ grep -E 'RssAnon|RssFile' /proc/$pid/status; sleep 10; grep RssAnon /proc/$pid/status
RssAnon:     5752 kB
RssFile:     1408 kB
RssAnon:     7544 kB
```

Two proposals are on the table. One is a nightly restart. The other blames
the page cache, which module 03's `page-cache-versus-rss` already ruled out
here: the growth is `RssAnon`, memory the process allocated for itself, not
file pages the kernel can drop. A table of 3000 entries should stop growing
once it is full. Something allocates and never frees.

## Watching allocations in a live process

`memleak` (from libbpf-tools) attaches uprobes to `malloc`, `calloc`,
`free` and friends in the running process, records the stack of every
allocation, and forgets it when it is freed. What it prints is what is still
outstanding, grouped by the stack that allocated it, largest last:

```
memleak -p "$pid" 10 3
```

That prints every 10 seconds, three times. An allocation site whose
outstanding total keeps climbing from one report to the next is the leak. A
site that is large and steady is just memory in use. Only allocations made
after memleak attaches are tracked, so the table, filled at startup, does not
appear.

The stack reads innermost first: the allocator (`malloc`, `strdup`) at the
top, then the function that called it, then its caller. The allocation site
is the first frame in the program's own code.

memleak costs something on every allocation, and this process makes 5000 a
second. Run it for as long as it takes to see the trend, and stop it.

## Your objectives

1. Write the function whose allocations are leaking to
   `/root/answers/heap.txt`:

   ```
   allocation_site=<function>
   ```

2. Fix `/usr/local/src/session-cache/session-cache.c` (`make -C
   /usr/local/src/session-cache install`, then restart the unit) so the
   process's anonymous memory stops growing.

## What you're being graded on

The check reads your answer, then soaks the running service for 20 seconds
on one PID: no restart during the soak, no worker processes or threads, at
least 4000 lookups a second, and `RssAnon` must grow by no more than 512 kB.
The unfixed service grows several megabytes in that time. A restart policy
does not pass: it moves the cliff, and the soak sees the slope.

<details>
<summary>Hint 1 — which stack</summary>

Compare two consecutive memleak reports. One stack's outstanding bytes and
allocation count grow by about the same amount every interval. Read the
function just below `strdup` in that stack.

</details>

<details>
<summary>Hint 2 — who owns the copy</summary>

`normalize_key()` returns a fresh copy. Follow it through `lookup()`: on a
miss the table keeps it (and frees the one it replaces). On a hit?

</details>

<details>
<summary>Solution</summary>

```
	3612672 bytes in 56448 allocations from stack
		0 [<0000ffff9b4e1a2c>] strdup+0x1c [libc.so.6]
		1 [<0000aaaad5e10b44>] normalize_key+0x14 [session-cache]
		2 [<0000aaaad5e10c80>] lookup+0x20 [session-cache]
		3 [<0000aaaad5e10e10>] main+0x90 [session-cache]
```

```
allocation_site=normalize_key
```

`lookup()` normalises the key into a new string. On a miss it hands that
string to the table. On a hit it returns the cached token and drops the
string on the floor. With 3000 sessions, nearly every lookup is a hit:

```c
    if (e->key && strcmp(e->key, key) == 0) {
        hits++;
        free(key);
        return e->token;
    }
```

### Leaks in production

- A restart is a fine mitigation while the fix ships. It is not a fix: the
  ramp starts again, and the restart has to happen before the cliff,
  forever.
- Separate the kinds of memory first. `RssAnon` growing is the program's
  own allocations; `RssFile` and page cache growing is files being read and
  is reclaimable. `smem`, `/proc/<pid>/smaps_rollup` and the cgroup's
  `memory.stat` (`anon` against `file`) tell them apart.
- In a garbage-collected language a "leak" is something still referenced: a
  cache with no bound, a listener never removed. The heap profiler of that
  runtime (`tracemalloc`, `pprof` heap, a JVM heap dump) answers the same
  question memleak does: what is holding it, and from where was it
  allocated.

</details>
