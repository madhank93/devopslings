---
title: "kill -9, and it is still there"
---

## The situation

`vault-verify` reads the vault volume end to end every night to prove it is
readable. It normally takes a second. It has been running for an hour:

```
$ systemctl status vault-verify.service
● vault-verify.service - Verify the vault volume reads end to end
     Active: activating (start) since 02:00:01; 1h ago
   Main PID: 612 (dd)
$ kill -9 612; sleep 5; ps -o pid,stat,cmd -p 612
  PID STAT CMD
  612 D    /usr/bin/dd if=/dev/vault of=/dev/null bs=64k iflag=direct
$ cat /proc/loadavg
1.08 1.04 0.97 ...
```

`SIGKILL` cannot be caught, blocked or ignored, and it did nothing. The
load average is up by one, on a box doing no work. Module 01's
`blocked-on-a-pipe` looked similar: a process asleep for hours. That one was in
`S` and died the moment it was signalled. This one is in `D`.

## Two kinds of sleep

A task that waits inside the kernel sleeps in one of two ways:

- **`S`, interruptible.** Waiting for something that may never come: a pipe
  writer, a network packet, a timer. A signal wakes it, the system call returns
  `EINTR`, and the signal is handled on the way back to user space.
- **`D`, uninterruptible.** Waiting for something the kernel has promised to
  finish, usually I/O already handed to a device. A signal is marked pending
  and nothing else: the task cannot leave the kernel until the I/O completes,
  and a signal is only acted on when a task returns to user space.

That is also why load climbs: Linux counts tasks in `D` in the load average,
alongside running ones. One stuck reader is +1, for as long as it stays stuck.

## Asking the task what it waits for

While the task is alive, the kernel will say where it is sleeping:

- `/proc/<pid>/status`, the `State:` line: the letter, spelled out.
- `/proc/<pid>/wchan`: the kernel function the task is sleeping in.
- `/proc/<pid>/stack` (root): the whole kernel call stack, from the system
  call down to that function.

Then follow the device. `/dev/vault` is a device-mapper volume, like the LVM
volumes in module 03; `dmsetup info` shows each mapping's state, and a
`SUSPENDED` mapping queues every I/O sent to it until it is resumed. Storage
failover does this on purpose, so that I/O waits for the new path instead of
failing. Here the failover finished and nobody resumed the path.

## Your objectives

1. Before changing anything, write what the live task shows to
   `/root/answers/dstate.txt`:

   ```
   state=<the state letter>
   wchan=<the kernel function it sleeps in>
   why=<why kill -9 did not end it>
   ```

2. Let the verifier finish, without changing the volume's mapping.

## What you're being graded on

The check compares `state` and `wchan` with what the stuck task showed when
the scenario started, and looks for the kind of sleep in `why`. Then the
volume must be active with its original mapping, the stuck process must be
gone, and a fresh run of `vault-verify.service` must read the whole volume.

<details>
<summary>Hint 1 — reading the task</summary>

```
pid=$(systemctl show -p MainPID --value vault-verify.service)
grep State /proc/$pid/status; cat /proc/$pid/wchan; echo; cat /proc/$pid/stack
```

The stack names the system call at the bottom and the block layer above it.

</details>

<details>
<summary>Hint 2 — what it is waiting for</summary>

`dmsetup info devopslings-vault`. The I/O is not lost, only queued; `dmsetup
resume` lets it through.

</details>

<details>
<summary>Solution</summary>

```
$ grep State /proc/612/status; cat /proc/612/wchan; echo; cat /proc/612/stack
State:	D (disk sleep)
submit_bio_wait
[<0>] submit_bio_wait+0x5c/0x98
[<0>] blkdev_direct_IO+0x410/0x4d8
[<0>] blkdev_read_iter+0xf0/0x180
[<0>] __arm64_sys_read+0x194/0x440
```

```
state=D
wchan=submit_bio_wait
why=uninterruptible sleep waiting for block I/O on a suspended volume; a signal is acted on only when the task returns to user space, so SIGKILL stays pending until the I/O completes
```

`dd` submitted a read to `/dev/vault` and is waiting for it to complete.
`devopslings-vault` is `SUSPENDED`, so the read is queued in device mapper
and never reaches the disk. Resume the path:

```
dmsetup resume --noudevsync devopslings-vault
```

The queued read completes, `dd` returns to user space, and either finishes
the volume or, if you had sent `SIGKILL`, dies of it on the way out.

### D state in production

- NFS hard mounts, a hung iSCSI or multipath device with `queue_if_no_path`,
  and a stalled disk all produce this: tasks in `D`, unkillable, load average
  rising without CPU use. `ps -eo pid,stat,wchan:32,cmd | awk '$2 ~ /D/'`
  lists them with what they wait in.
- `echo w > /proc/sysrq-trigger` dumps every blocked task's stack to the
  kernel log, and the hung-task detector logs tasks stuck in `D` for longer
  than `kernel.hung_task_timeout_secs`.
- Rebooting is often the only way out when the device never comes back. Find
  the device first, so the reboot is the last resort, not the first guess.

</details>
