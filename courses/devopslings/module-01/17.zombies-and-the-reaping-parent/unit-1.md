---
title: "two thousand processes you cannot kill, because they are already dead"
---

## The situation

`ps` is filling up with these:

```
$ ps -eo pid,ppid,stat,cmd | grep defunct | head -3
   1841    1802 Z    [job-runner] <defunct>
   1843    1802 Z    [job-runner] <defunct>
   1845    1802 Z    [job-runner] <defunct>

$ ps -eo stat= | grep -c '^Z'
1974
```

And `kill -9` does nothing at all:

```
$ kill -9 1841
$ echo $?
0
$ ps -p 1841 -o stat=
Z
```

The signal was accepted — exit status 0, no error — and the entry is still
there. That combination is worth sitting with for a moment, because it rules out
almost everything.

## Your objectives

| file | answer |
|---|---|
| `/root/answers/why` | one of `alreadydead`, `permissions`, `blocked`, `uninterruptible` |

Then stop them accumulating. `job-runner` must still be running and still
completing jobs — the check watches its counter advance, then counts the
defunct children it left behind.

## What you're being graded on

The mechanism named, the counter still moving, and near-zero zombies parented by
`job-runner` after ten seconds of sustained work. Stopping the service removes
the zombies and fails: the jobs still have to run.

<details>
<summary>Hint 1 — what state Z actually is</summary>

A zombie is not a process. It is a **table entry**.

When a process exits, almost everything goes immediately: its memory, its open
files, its threads. One thing is kept — the exit status — because the parent may
want it. The kernel holds a slot in the process table containing that status and
nothing else, until the parent collects it with `wait()`.

That slot is what `ps` shows as `Z` / `<defunct>`.

So there is no code, no memory, no execution context. A signal is a request to
interrupt a running thing, and there is no running thing. The kernel accepts the
call and has nothing to deliver it to — which is exactly why `kill -9` returns 0
and changes nothing.

Rule out the others while you are here:

- **permissions** — you are root, and `kill` returned 0. A rejected signal
  returns `EPERM` and a non-zero status.
- **blocked** — `SIGKILL` cannot be caught, blocked or ignored by anything.
- **uninterruptible** — that is state `D`, and it does defer signals. These are
  `Z`. The state letter is the answer.

</details>

<details>
<summary>Hint 2 — find the parent, because that is the only live thing here</summary>

Zombies are the parent's problem, so look at the second column:

```
$ ps -eo stat=,ppid= | awk '$1 ~ /^Z/ {print $2}' | sort | uniq -c | sort -rn
   1974 1802

$ ps -p 1802 -o pid,cmd
   1802 /usr/bin/python3 /usr/local/bin/job-runner
```

One parent, all of them. That process is alive, running, and never calling
`wait()`.

```python
pid = os.fork()
if pid == 0:
    ...
    os._exit(0)

done += 1        # parent goes straight on to the next job
```

Every iteration forks a child, the child finishes in 50 ms, and its exit status
sits in the table forever because nobody asks for it.

</details>

<details>
<summary>Hint 3 — two ways for a parent to do its job</summary>

**Collect them.** `waitpid(-1, WNOHANG)` returns any child that has finished, or
`0` immediately if none has. It never blocks, so it is safe to call in a loop:

```python
while True:
    reaped, status = os.waitpid(-1, os.WNOHANG)
    if reaped == 0:
        break
```

**Or decline the statuses entirely.** Setting `SIGCHLD` to `SIG_IGN` tells the
kernel not to keep exit statuses for this process's children at all:

```python
signal.signal(signal.SIGCHLD, signal.SIG_IGN)
```

Simpler, and you give up ever knowing whether a worker failed. For a job runner
that is usually the wrong trade — a worker exiting non-zero is precisely the
thing you want to find out about.

There is a third option people reach for: restart the parent. When a parent
dies, its children are re-parented to PID 1, and PID 1 reaps continuously. That
does clear the table, and it fixes nothing — the new `job-runner` starts
producing zombies immediately.

</details>

<details>
<summary>Solution</summary>

```
$ echo alreadydead > /root/answers/why
```

```python
    # Collect everything that has finished since the last pass. WNOHANG means
    # this never blocks: if no child is ready, it returns immediately.
    while True:
        try:
            reaped, status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            break
        if reaped == 0:
            break
        if os.waitstatus_to_exitcode(status) != 0:
            failed += 1
```

```
$ systemctl restart job-runner
$ sleep 10
$ ps -eo stat=,ppid= | awk -v p=$(systemctl show -p MainPID --value job-runner) \
    '$1 ~ /^Z/ && $2 == p' | wc -l
0
```

### Why this is a lesson at all

Three things, and the first is the one that saves the most time.

1. **A signal that "does nothing" is telling you the target is not what you
   think.** `kill -9` returning 0 while nothing changes is not a broken kernel
   or a stuck process; it means there is no process there. Read the state
   letter before deciding what a process is doing — `R`, `S`, `D`, `Z` and `T`
   mean genuinely different things, and only one of them is "running".

2. **Zombies are an accounting leak, not a resource leak.** Each one costs a
   table slot and essentially no memory. That is why this is quiet for a long
   time, and then abrupt: nothing degrades gradually, and then the box hits
   `kernel.pid_max` and *no process anywhere can fork*. The failure lands
   nowhere near the service that caused it.

3. **The fix is always in the parent.** You cannot fix a zombie; there is
   nothing there to fix. This is a general shape — the visible artefact and the
   thing to change are different objects, and pointing tools at the artefact
   produces the "I tried everything and nothing worked" hour. `blocked-on-a-pipe`
   earlier in this module has the same structure: the process everyone stares at
   is the one that is fine.

This is also exactly why containers need a real init when PID 1 forks children,
and why `pid1-signals` in module 09 is the next place you will meet it.

</details>
