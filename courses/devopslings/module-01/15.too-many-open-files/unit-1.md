---
title: "EMFILE, and the ulimit that never reached the service"
---

## The situation

`feed-gateway` will not stay up.

```
$ journalctl -u feed-gateway -o cat -n 4
feed-gateway: ready, 0 shards open
Traceback (most recent call last):
  File "/usr/local/bin/feed-gateway", line 8, in <module>
OSError: [Errno 24] Too many open files: '/srv/feed/shards/shard-61.log'
```

It dies at shard 61 of 90. Somebody has already tried the obvious thing:

```
$ ulimit -n
1024
$ systemctl restart feed-gateway     # same failure, same shard
```

The shell says 1024. The service disagrees. Both are correct, and the reason is
the first half of this lesson.

## Your objectives

1. Give the gateway a descriptor limit it can work under. It holds 90 shard
   handles open for its whole life and that is legitimate. Set the limit **where
   systemd reads it**.
2. Then stop it leaking. The check pushes two load batches through **one**
   process and compares its open descriptor count between them.

Every job queued must end up in `/srv/feed/processed.log`.

## What you're being graded on

Both, independently. Raising the limit gets it started and it will still fail
later. Fixing the leak alone leaves it unable to start at all, because 90 shards
do not fit in 64 descriptors no matter how tidy the code is.

<details>
<summary>Hint 1 — why your shell's ulimit is irrelevant</summary>

Limits are per-process and **inherited from the parent**. When you type `ulimit
-n 4096`, you change your shell, and every process your shell then forks.

`feed-gateway` was not forked by your shell. It was forked by PID 1. Your shell
is nowhere in its ancestry, so nothing you do there can reach it.

Ask the process itself rather than the shell:

```
$ pid=$(systemctl show -p MainPID --value feed-gateway)
$ grep 'open files' /proc/$pid/limits
Max open files            64                   64                   files

$ systemctl show -p LimitNOFILE feed-gateway.service
LimitNOFILE=64
```

For anything systemd starts, the unit is the only place that matters:

```ini
[Service]
LimitNOFILE=4096
```

`/etc/security/limits.conf` is another common dead end here — that is applied by
PAM at **login**, so it governs interactive sessions and cron, and never touches
a systemd service either.

</details>

<details>
<summary>Hint 2 — a drop-in, so the unit stays upgradeable</summary>

```
$ install -d /etc/systemd/system/feed-gateway.service.d
$ cat > /etc/systemd/system/feed-gateway.service.d/nofile.conf <<'CONF'
[Service]
LimitNOFILE=4096
CONF
$ systemctl daemon-reload
$ systemctl restart feed-gateway
```

Confirm it landed, in the process rather than in the config:

```
$ grep 'open files' /proc/$(systemctl show -p MainPID --value feed-gateway)/limits
```

It starts now. That is half.

</details>

<details>
<summary>Hint 3 — watch the descriptors, not the errors</summary>

Run a batch and count:

```
$ pid=$(systemctl show -p MainPID --value feed-gateway)
$ ls /proc/$pid/fd | wc -l
95
$ feed-load 150
$ ls /proc/$pid/fd | wc -l
245
```

150 jobs in, 150 descriptors that never came back. The steady state should be
95 — the 90 shards plus stdio — regardless of how much traffic went through.

Look at what they point at:

```
$ ls -l /proc/$pid/fd | awk '{print $NF}' | sort | uniq -c | sort -rn | head
```

Then find the line that keeps them:

```python
fh = open(path)
payload = fh.read().strip()
leaked.append(fh)     # <- retained for the life of the process
```

A `with` block scopes the handle to the request. In any language the rule is
the same: whoever opens it is responsible for closing it, and "the garbage
collector will get to it" is not a schedule you control.

</details>

<details>
<summary>Solution</summary>

```
$ install -d /etc/systemd/system/feed-gateway.service.d
$ printf '[Service]\nLimitNOFILE=4096\n' > /etc/systemd/system/feed-gateway.service.d/nofile.conf
```

```python
        try:
            with open(path) as fh:
                payload = fh.read().strip()
            ...
```

```
$ systemctl daemon-reload && systemctl restart feed-gateway
$ feed-load 150; sleep 5; ls /proc/$(systemctl show -p MainPID --value feed-gateway)/fd | wc -l
95
$ feed-load 150; sleep 5; ls /proc/$(systemctl show -p MainPID --value feed-gateway)/fd | wc -l
95
```

Flat. That is the property that matters — not the absolute number, but that it
does not depend on how much work has gone through.

### Why this is a lesson at all

`EMFILE` is one error covering two unrelated faults, and each has a fix that
does nothing for the other:

1. **The ceiling was wrong.** A service with 90 long-lived handles cannot run
   under 64, and no amount of careful coding changes that. The limit has to be
   set where the process actually gets it — which for a systemd service is the
   unit, never your shell and never `limits.conf`.

2. **The consumption was unbounded.** A leak is not a big number, it is a
   *slope*. Any ceiling is eventually reached; raising it converts "fails in ten
   minutes" into "fails on Sunday", which is worse, because it now fails at a
   time nobody connects to a change made on Thursday.

The diagnostic habit worth taking: measure the resource across two identical
runs and compare. Flat is healthy. Rising is a leak, whatever the absolute
number looks like. That same shape — `fd` counts here, memory in `oom-killed`,
inodes in `inodes-not-bytes`, disk in `journal-eats-the-disk` — is four
exercises in this module describing one failure mode, and the tell is always the
slope rather than the value.

And note `Restart=always` was quietly making it worse: every crash handed the
work to a fresh process with a fresh descriptor table, so the service looked
like it was recovering when it was really just resetting the counter on a leak
nobody had found.

</details>
