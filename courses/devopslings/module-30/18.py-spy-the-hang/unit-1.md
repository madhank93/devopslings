---
title: "0% CPU, and the settlements stopped an hour ago"
---

## The situation

`settle-worker` moves settled payments from the ledger into the fee pool. A
second thread, the reconciler, checks that the two balances still add up.
Every few hours the worker stops:

```
$ systemctl status settle-worker.service
● settle-worker.service - Payment settlement worker
     Active: active (running) since 03:11:52; 1h 4min ago
$ cat /var/lib/settle/progress
577 16
$ ps -o pid,stat,%cpu,time,cmd -C python3
  PID STAT %CPU     TIME CMD
  841 Sl    0.0 00:00:00 /usr/bin/python3 /opt/settle/worker.py
```

Active, alive, 0% CPU, and the counts have not moved in an hour. The runbook
says to restart it, which works, until the next time. Module 01's
`blocked-on-a-pipe` was waiting in the kernel, so `wchan` named the wait.
Here `/proc/<pid>/wchan` says `futex_wait` for every thread, which is true
and useless: every Python lock is a futex. The wait is in the interpreter, and
so is the answer.

## Reading a live Python process

`py-spy` reads a running Python process's memory from the outside and
reconstructs each thread's Python stack. The process is not stopped, signalled
or modified, and it does not have to have been started with any special flag:

```
py-spy dump --pid "$(systemctl show -p MainPID --value settle-worker.service)"
```

```
Thread 0x7f3a1c6f0700 (idle): "settler"
    settle_one (worker.py:28)
    loop (worker.py:51)
    ...
```

Each thread is listed by its name, innermost frame first: the function and
line it is executing right now. `(idle)` means it is not holding the GIL — it
is waiting for something. Add `--locals` to see each frame's local variables.

A deadlock is two threads, each holding one lock and blocked acquiring the
other's. The dump shows where each is blocked; the code above that line shows
what it already holds.

## Your objectives

1. Before restarting anything, write the lock each thread is blocked
   acquiring to `/root/answers/hang.txt`:

   ```
   settler_waits_for=<lock name>
   reconciler_waits_for=<lock name>
   ```

2. Fix `/opt/settle/worker.py` so it cannot deadlock.

## What you're being graded on

The check reads your answer, then stress-tests `/opt/settle/worker.py`: 2000
rounds per thread, back to back, which deadlocks the original within a few
hundred. Every round must complete, and the reconciler must never catch the
balances out of step: money that is debited and not yet credited looks
missing.

<details>
<summary>Hint 1 — reading the dump</summary>

Open `/opt/settle/worker.py` at the line numbers the dump gives for
`settle_one` and `reconcile_one`. Each is a `with ...lock:` line. Now read the
`with` statements that enclose each of those lines.

</details>

<details>
<summary>Hint 2 — the fix that holds</summary>

A deadlock needs a cycle: A holds X and wants Y while B holds Y and wants X.
If every thread takes the locks in the same order, there is no cycle. Dropping
a lock removes the deadlock and lets the reconciler see a half-finished move;
timing out on a lock and skipping the round loses the round.

</details>

<details>
<summary>Solution</summary>

```
Thread 0x... (idle): "settler"
    settle_one (worker.py:28)          with fees_lock:
Thread 0x... (idle): "reconciler"
    reconcile_one (worker.py:37)       with ledger_lock:
```

```
settler_waits_for=fees_lock
reconciler_waits_for=ledger_lock
```

`settle_one` takes `ledger_lock` then `fees_lock`; `reconcile_one` takes
`fees_lock` then `ledger_lock`. When each gets its first lock before the other
gets its second, both wait forever. The journal write inside each critical
section widens the window enough that it happens every few hours.

Take them in one order everywhere:

```python
def reconcile_one():
    with ledger_lock:
        journal()
        with fees_lock:
            if ledger["cents"] + fees["cents"] != TOTAL:
                stats["mismatches"] += 1
    stats["reconciled"] += 1
```

### Lock ordering in real code

- Write the order down next to the locks, and make every path follow it. A
  codebase with N locks and no order has N² chances to get it wrong.
- `py-spy dump` works the same on a Gunicorn worker or a Celery process: find
  the PID, dump it, read the innermost frame of each thread. For Java,
  `jstack` does this and names the deadlock for you; for Go, `SIGQUIT` dumps
  every goroutine.
- Dump before you restart. A restart is the right mitigation and it destroys
  the only evidence of which interleaving happened.

</details>
