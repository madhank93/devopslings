---
title: "receipts broke the day AppArmor went to enforce"
---

## The situation

`receipt-render.service` renders receipts at `http://127.0.0.1:8088/receipt/<id>`.
It has run under an AppArmor profile in complain mode for months. Yesterday the
hardening rollout switched every profile to enforce, and since then every
receipt is a 500:

```
$ curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8088/receipt/1001
500
$ journalctl -u receipt-render | tail -n 1
... python3[137]: render failed for receipt 1001
```

The first guess writes itself, and someone has already proposed it: put the
profile back in complain mode, or switch AppArmor off for the service. Both make
the 500s stop, and both throw away the thing the rollout was for. Complain mode
denies nothing; it only writes down what it would have denied.

The profile is right about almost everything. Find the one thing it is wrong
about, and allow exactly that.

> **This lesson needs a Linux Docker host with AppArmor** (Ubuntu, Debian,
> openSUSE). The box shares your kernel, and the kernels in macOS Docker VMs
> (OrbStack, Docker Desktop) are built without AppArmor, so devopslings will
> not start it there. The profile you load is loaded into your host's kernel:
> its name, `receipt-render`, is unique to this lesson, and it is gone at the
> next reboot or with `sudo apparmor_parser -R` on the host. Do not run
> `aa-teardown` in the box — it would unload your host's profiles too.

## Your objectives

- Find the denial that breaks rendering in the kernel log
- Change `/etc/apparmor.d/receipt-render` so the service works in enforce mode
- Paste the denial into `/root/answers/denial.md`

## What you're being graded on

The grader reloads the profile from `/etc/apparmor.d/receipt-render`, restarts
the service, and checks:

- the profile is loaded in **enforce** mode, and the running service is
  confined by it (`AppArmorProfile=` stays in the unit)
- a receipt with an ID it picks renders, and lands in the service's cache
- the profile still refuses what the service never needed: reading
  `/etc/shadow`, writing the receipt template, and creating files anywhere in
  `/var/lib/receipt-render` other than the cache
- `/root/answers/denial.md` quotes the `apparmor="DENIED"` line for the failing
  request, as the kernel logged it

<details>
<summary>Hint 1 — where AppArmor writes</summary>

AppArmor reports a denial through the kernel's audit subsystem. With `auditd`
running, those records go to `/var/log/audit/audit.log`; without it, the kernel
prints them to its own log:

```
$ dmesg | grep 'apparmor="DENIED"'
```

The service's own log says nothing useful on purpose — plenty of real services
catch the `EACCES` and log a generic failure. The kernel is the only witness
that names the path.

The kernel rate-limits how many audit lines it prints, and the burst from
loading a profile can use up the allowance. If the newest request has no line
yet, send another and look again.

</details>

<details>
<summary>Hint 2 — reading a denial</summary>

```
apparmor="DENIED" operation="mknod" class="file" profile="receipt-render"
  name="/var/lib/receipt-render/cache/1001.txt" comm="python3"
  requested_mask="c" denied_mask="c"
```

`profile` is who was refused, `name` is the path, and `denied_mask` is the
permission it lacked: `r` read, `w` write, `c` create, `a` append, `k` lock.
`operation="mknod"` is a file being created. Compare `name` with the rules in
the profile: which directory does the service write to, and which one does the
profile let it write?

</details>

<details>
<summary>Hint 3 — narrow enough</summary>

`/** rwk` makes the denial go away and makes the profile meaningless. So does
`/var/lib/receipt-render/** rw`: the signing key lives there, and a service that
can write next to its key can replace it. The rule the denial asks for covers
the cache directory and nothing else. After editing:

```
$ apparmor_parser -r /etc/apparmor.d/receipt-render
$ aa-status | grep -A1 receipt-render
```

A replaced profile applies to the running process immediately; no restart
needed.

</details>

## Why complain mode lied

Complain mode logs `apparmor="ALLOWED"` for the same events enforce denies — it
is a dry run. The service passed it for months because release 2.4 moved its
render cache from `/var/cache/receipt-render` to `/var/lib/receipt-render/cache`,
and nobody read the dry run's output when the path changed. The profile was
written for 2.3. Enforce made a stale profile visible; it did not create the
problem.

That is the general shape of an AppArmor (or SELinux) outage: the policy was
written for the software as it was, the software moved, and the error the
software reports is a bare "permission denied" that file permissions cannot
explain. `ls -l` says the service owns its cache. The kernel log says why it
still cannot write there.

## Checking yourself

```
$ curl -s http://127.0.0.1:8088/receipt/4242
RECEIPT #4242
...
$ ls /var/lib/receipt-render/cache/4242.txt
$ grep '^receipt-render ' /sys/kernel/security/apparmor/profiles
receipt-render (enforce)
$ runuser -u receipts -- aa-exec -p receipt-render -- touch /var/lib/receipt-render/x
touch: cannot touch '/var/lib/receipt-render/x': Permission denied
```

<details>
<summary>Solution</summary>

Add one rule next to the old cache path, which can stay or go:

```
  /var/cache/receipt-render/** rw,
  /var/lib/receipt-render/cache/** rw,
```

```
$ apparmor_parser -r /etc/apparmor.d/receipt-render
$ dmesg | grep 'apparmor="DENIED"' | grep receipt-render/cache | tail -n 1 > /root/answers/denial.md
```

</details>
