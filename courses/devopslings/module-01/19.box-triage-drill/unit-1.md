---
title: "orders cannot take an order, and the box will not say why"
---

## The situation

```
$ curl -sS -m 5 -X POST --data 'sku=A-100&qty=1' http://127.0.0.1:8088/orders
```

It should print `order accepted ORD-…`. It does not. That is the entire ticket,
and it will be the entire ticket every time you run this lesson — because the
fault is drawn at random from five, and each is a different way one Linux box
stops a service writing.

`orders.service` runs `/opt/orders/orders.py` as the user `orders` and reads
`/etc/orders/orders.conf`. Everything it writes goes to `/srv/orders`, its own
filesystem: one file per order in `spool/`, a line in `log/orders.log`, a line
in a ledger shard. `GET /` on the same port answers `ok` whenever the process
is up, which is exactly why nobody noticed.

You cannot memorise the answer. You can memorise the order of the questions.

## Your objectives

- Make `POST /orders` succeed again by repairing what broke, where it broke
- Write `/root/answers/triage.md`, three lines:

  ```
  cause:     <what was wrong, in a few words>
  evidence:  <the command or number that proved it>
  detection: <a signal and a threshold that would have paged first>
  ```

## What you're being graded on

The grader posts its own order. Then it checks that the repair is at the cause
rather than around it:

- **orders.service serves the port**, as the user `orders`, running the
  unchanged `/opt/orders/orders.py`. A copy started by hand, or a unit switched
  to `root`, hides the problem instead of removing it.
- **the config still points at `/srv/orders`.** Moving the spool or the log
  somewhere that works leaves 40 pending orders where it does not.
- **`/srv/orders` is the filesystem it was**: 48M, 4000 inodes. Remounting it
  bigger is not something a real disk lets you do mid-incident.
- **the spool is not world-writable**, and all 40 pending orders are still in it.
- **whatever held, filled or limited is fixed where systemd reads it**, and
  stays fixed across a restart.
- **`log/orders.log.1` is untouched.** It is big, it is full of `ERROR`, and it
  is innocent.

And `triage.md`: `cause` must describe the fault that was seeded; `evidence`
must be the command or counter that proves that fault; `detection` must name a
signal that fits it *and* a number.

<details>
<summary>Hint 1 — the questions, in order</summary>

```
$ systemctl status orders          # is it even running?
$ journalctl -u orders -n 20       # what did it say, in its own words?
$ df -h /srv/orders                # bytes
$ df -i /srv/orders                # inodes
$ lsof -nP +L1                     # space with no name
$ namei -l /srv/orders/spool       # can orders reach and write it?
$ cat /proc/$(systemctl show -p MainPID --value orders)/limits
$ ls /proc/$(systemctl show -p MainPID --value orders)/fd | wc -l
```

The error message narrows it; it does not finish it. Two of the five faults
print the identical `No space left on device`.

</details>

<details>
<summary>Hint 2 — the biggest thing is not always the thing</summary>

`du` answers "which names use space". `df` answers "how much is used". When they
disagree, the gap is space that belongs to no name — a file deleted while
something still has it open. When `df -h` looks fine and writes still fail with
`ENOSPC`, count files instead of bytes.

A large, recent, error-filled log is the first thing anyone deletes. Ask
whether anything has it open before you touch it — and whether deleting it
would free what is actually missing.

</details>

<details>
<summary>Hint 3 — where systemd reads it</summary>

A service does not inherit your shell. Its user, its limits and its hardening
come from the unit and its drop-ins: `systemctl cat orders` shows every file
that contributes, in order. A limit changed with `prlimit` on the live process,
a `ulimit` in your shell, or a process restarted with `kill` all last until the
next restart. `systemctl reset-failed` is how a unit that stopped retrying is
allowed to try again.

</details>

## What actually happened

| Fault | What was done | What the service says | The tell |
|---|---|---|---|
| disk | `orders-export.service` filled `/srv/orders/log/export.tmp`, unlinked it and kept the descriptor | `No space left on device` | `df` 100%, `du` 12M, `lsof +L1` shows the deleted file |
| inodes | an aborted import left ~3900 empty `spool/.incoming/*.part` files | `No space left on device` | `df -h` has room; `df -i` is at 100% |
| config | `port = 8O88` — a letter O — in `orders.conf` | nothing on the port; the unit is `failed` | `ValueError: invalid literal for int()` in the journal |
| nofile | a hardening drop-in set `LimitNOFILE` one above what the idle process holds | `Too many open files` | the fd count equals `Max open files` in `/proc/<pid>/limits` |
| perms | `spool/` came back from a backup `root:root 0755` | `Permission denied` | `namei -l` shows the directory; the service is `User=orders` |

The red herring, every run: `log/orders.log.1`, 12M, rotated two hours ago,
thousands of `ERROR payments upstream timeout` lines that were retried and
resolved. Nothing holds it open. Deleting it frees 12M, which for the disk fault
makes orders work for a few minutes and leaves the real hog in place.

<details>
<summary>Solution</summary>

Ask in order and repair at the first question that answers.

```bash
# config: the unit is not running at all
systemctl status orders; journalctl -u orders -n 20
sed -i 's/^port = .*/port = 8088/' /etc/orders/orders.conf
systemctl reset-failed orders && systemctl start orders

# disk: space with no name
df -h /srv/orders; du -sh /srv/orders; lsof -nP +L1
systemctl disable --now orders-export      # stop the unit, not the PID

# inodes: ENOSPC with bytes free
df -i /srv/orders
find /srv/orders/spool/.incoming -name '*.part' -size 0 -delete

# perms: can orders write where it writes?
namei -l /srv/orders/spool
chown orders:orders /srv/orders/spool && chmod 2770 /srv/orders/spool

# nofile: count against the limit systemd gave it
pid=$(systemctl show -p MainPID --value orders)
ls /proc/$pid/fd | wc -l; grep 'open files' /proc/$pid/limits
systemctl cat orders                      # the drop-in that set it
sed -i 's/^LimitNOFILE=.*/LimitNOFILE=4096/' \
  /etc/systemd/system/orders.service.d/10-hardening.conf
systemctl daemon-reload && systemctl restart orders
```

Keep `NoNewPrivileges=yes` in that drop-in: the hardening was right, its limit
was not.

Then, for example:

```
cause: inodes exhausted by empty .part files from an aborted import
evidence: df -i /srv/orders showed IUse% 100 with bytes free
detection: df -i IUse% > 80% on /srv/orders
```

</details>

## Carrying this forward

- **Ask whether it runs before asking why it fails.** A unit in `failed` state
  has a journal; a running one that returns errors has a resource or a
  permission problem.
- **The same errno has more than one home.** `ENOSPC` is bytes or inodes; only
  `df` and `df -i` side by side tell which.
- **Fix it where systemd reads it.** Limits, users and restarts live in the
  unit; anything done to the live process is undone by the next restart.
- **Leave the alarming thing alone until it is proven guilty.** The biggest,
  noisiest file on the box is the one everybody deletes first.

Run the lesson again. The fault moves, and the questions do not.
