---
title: "the setuid hunt, where the dangerous binary and sudo look identical"
---

## The situation

Something on this box lets an unprivileged user become root instantly:

```
$ sudo -u probe /usr/local/bin/maint -p -c id
uid=1000(probe) gid=1000(probe) euid=0(root) groups=1000(probe)
```

`euid=0` — the process is running with root's authority. `maint` is a copy of
`bash` with the setuid bit set and owned by root, which means the kernel runs it
as root no matter who starts it. `-p` tells bash to keep those privileges rather
than drop them. It is a root shell wearing a maintenance-tool name, and there is
a second one like it somewhere else on the disk.

Finding them is a one-liner:

```
$ find / -xdev -perm -4000 -type f
/usr/bin/chfn
/usr/bin/chsh
/usr/bin/gpasswd
/usr/bin/mount
/usr/bin/newgrp
/usr/bin/passwd
/usr/bin/su
/usr/bin/sudo
/usr/bin/umount
/usr/local/bin/maint
/opt/tools/backup
```

Eleven setuid-root binaries. Two are backdoors. Nine are load-bearing. The
difficulty of this lesson is not the search — it is telling which is which
without breaking the box.

## The mode does not tell you

```
$ ls -l /usr/bin/sudo /usr/local/bin/maint
-rwsr-xr-x 1 root root  /usr/bin/sudo
-rwsr-xr-x 1 root root  /usr/local/bin/maint
```

Identical. Same owner, same `s` bit, same everything a permission listing shows.
Both run as root; both are, mechanically, a way to execute code as root. `sudo`
is the one you rely on to become root deliberately, and `maint` is the one an
attacker left so they don't have to. Nothing in the file's mode distinguishes a
tool you trust from a tool left to exploit you.

This is why the tempting fix is a disaster:

```
# Do NOT do this.
$ find / -perm -4000 -exec chmod u-s {} \;
```

It removes the setuid bit from *everything*, including sudo. The two backdoors
die — and so does your ability to become root at all. `su`, `passwd`, `mount`
go with them. You have hardened the machine into a brick.

## Provenance is the signal

The thing that separates the nine from the two is not on the file. It is in the
package database.

Every setuid binary a Debian system is supposed to have arrived in a package,
and dpkg records which file came from where. The backdoors were copied in by
hand, so no package claims them:

```
$ dpkg -S /usr/bin/sudo
sudo: /usr/bin/sudo

$ dpkg -S /usr/local/bin/maint
dpkg-query: no path found matching pattern /usr/local/bin/maint
```

That is the whole test. A setuid binary that dpkg owns is part of the system's
designed attack surface — audited, updatable, expected. A setuid binary dpkg
does not own was placed by a human, and on a server the only humans placing
setuid-root binaries by hand are making a mistake or an intrusion. Either way it
does not belong.

So the hunt is two commands composed: list the setuid binaries, and keep only
the ones no package explains.

```
$ find / -xdev -perm -4000 -type f 2>/dev/null | while read -r f; do
    dpkg -S "$f" >/dev/null 2>&1 || echo "unowned: $f"
  done
unowned: /usr/local/bin/maint
unowned: /opt/tools/backup
```

Two lines out. Those are the two to remove — and only those.

## A note on the nine, and on ping

The nine legitimate ones are setuid for reasons worth knowing, because "why does
this need root" is the question you will actually be asked. `passwd` writes to
`/etc/shadow`, which only root may touch. `mount`, `su`, `sudo`, `newgrp` all
switch to a privilege the calling user does not have. They are setuid because
the task genuinely requires it, and each is a small, audited program whose whole
job is to do that one privileged thing and drop back.

`ping` is the classic tenth name in this list — it used to be setuid so it could
open a raw socket. On this box it is not, and it still works:

```
$ ls -l $(command -v ping)
-rwxr-xr-x 1 root root /usr/bin/ping
$ sudo -u probe ping -c1 127.0.0.1
64 bytes from 127.0.0.1: ...
```

Modern Linux lets unprivileged processes open ICMP sockets through the
`net.ipv4.ping_group_range` sysctl, so ping no longer needs the bit at all. The
trap this closes is the opposite of the blanket strip: an admin who "knows" ping
must be setuid and re-adds the bit is widening the attack surface for a capability
the kernel already grants safely. Removing a setuid bit that is not needed is as
much a part of this job as keeping the ones that are.

<details>
<summary>Hint 1 — list them first</summary>

```
$ find / -xdev -perm -4000 -type f 2>/dev/null
```

Nine of the results are supposed to be there. Two are not. The list itself does
not tell you which; the next hint does.

</details>

<details>
<summary>Hint 2 — ask the package database</summary>

For each setuid binary, ask whether a package owns it:

```
$ dpkg -S /usr/bin/sudo          # sudo: /usr/bin/sudo
$ dpkg -S /usr/local/bin/maint   # no path found
```

The ones dpkg cannot place are the ones to remove.

</details>

<details>
<summary>Hint 3 — do not touch the packaged ones</summary>

Remove or de-setuid only the unowned binaries. Leave every `/usr/bin` entry
alone — stripping sudo's setuid bit is the failure this lesson is built around.

</details>

## Checking yourself

After removing the two, the same composed command should print nothing, and the
escalation should be gone:

```
$ find / -xdev -perm -4000 -type f 2>/dev/null | while read -r f; do
    dpkg -S "$f" >/dev/null 2>&1 || echo "unowned: $f"; done
$ sudo -u probe /usr/local/bin/maint -p -c id
bash: /usr/local/bin/maint: No such file or directory
```

And sudo must still work — the one-command proof that you did not overreach:

```
$ sudo -n true && echo "sudo intact"
```

<details>
<summary>Solution</summary>

```bash
# List every setuid-root binary no package owns, then remove those.
find / -xdev -perm -4000 -type f 2>/dev/null | while read -r f; do
  dpkg -S "$f" >/dev/null 2>&1 || sudo rm -f "$f"
done
sudo rmdir /opt/tools 2>/dev/null || true
```

```
unpackaged_setuid: 2
found_with: dpkg -S
```

</details>
