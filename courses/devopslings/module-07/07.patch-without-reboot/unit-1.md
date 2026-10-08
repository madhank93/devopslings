---
title: "the library is patched on disk and still running in memory"
---

## The situation

The overnight security run landed three updates — `/var/log/apt/history.log`
has the transaction — and one of them was the fix for libwidget. The file on disk
is the fixed version:

```
$ ls -l /opt/patchlab/libwidget.so.1
-rw-r--r-- 1 root root 133600 Aug 26 10:02 /opt/patchlab/libwidget.so.1
```

And the box is still vulnerable.

The box runs a service that cannot take unplanned downtime, so there are three
jobs: put the running services onto the fixed library without a reboot, work out
which update from that transaction genuinely does need a reboot, and make sure
the next night's security fixes land unattended without anything else riding
along.

## Your objectives

- Put every running service that still uses the pre-patch libwidget onto the
  fixed one, restarting only those services, without a reboot
- Work out which update in the transaction does not take effect until the
  machine reboots
- Make apt run unattended upgrades daily, from the security archive only, and
  never reboot the box on its own

## What you're being graded on

- no running process still maps the pre-patch libwidget, and every service that
  should be up is active
- apt's merged configuration parses, enables the daily unattended run, allows
  only security origins, and has automatic reboot off

`/root/answers/patch.md`, exactly three lines:

```
stale_library: <the library still mapped from memory after the patch>
found_with: <the marker in /proc/<pid>/maps that flags a stale mapping>
reboot_required: <the package from the transaction that needs a reboot>
```

<details>
<summary>Hint 1 — find the stale mappings</summary>

```
$ grep -l '(deleted)' /proc/*/maps
```

Each file listed belongs to a process still holding a replaced file open. Narrow
to the patched library:

```
$ grep -l 'libwidget.*(deleted)' /proc/*/maps
```

</details>

<details>
<summary>Hint 2 — pid to service, and the reboot candidate</summary>

```
$ cat /proc/<pid>/cgroup
```

The line ends in `<name>.service`. That is the unit to restart. For the reboot,
compare `uname -r` with the `Install:` and `Upgrade:` lines of the transaction in
`/var/log/apt/history.log`.

</details>

<details>
<summary>Hint 3 — the unattended policy</summary>

In `50unattended-upgrades`, delete (or comment out with `//`) every
`Origins-Pattern` entry that is not a security archive. Put the daily trigger in
a file of its own, conventionally `20auto-upgrades`:

```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
```

Then check the merged result with `apt-config dump`.

</details>

## A patched file is not a patched running system

A patched file is not a patched running system. When a process starts, it maps
the shared libraries it needs into its own memory and keeps that copy for its
entire life. Replacing the file on disk — which is exactly what `apt upgrade`
does — does not touch the copy already mapped in a running process. Every service
that was up before the patch is still executing the old, vulnerable code, and
will keep doing so until it restarts.

The kernel even tells you which processes are in this state. When a mapped file
is replaced, the old inode lives on as long as something holds it open, and its
entry in `/proc/<pid>/maps` is marked `(deleted)`:

```
$ grep libwidget /proc/$(systemctl show -p MainPID --value widget)/maps
...  /opt/patchlab/libwidget.so.1 (deleted)
```

`(deleted)` is the whole tell: this process is mapping a file that no longer
exists, because the version it is running was replaced underneath it.

## The roulette

There is a fix that always works and is almost always the wrong first reach:
reboot. A reboot restarts every process, so every mapping is rebuilt from the
patched files, and the box comes back clean. It also takes down every service on
the machine — including the ones that did not need it — and stakes the recovery
on a clean boot, which on a server that has been up for two years is its own
gamble. "Just reboot it" is the move you take when you do not know which
processes are affected. The skill is knowing.

Knowing is a scan. Every process that needs restarting is holding a `(deleted)`
mapping, so the list of them is one command:

```
$ grep -l '(deleted)' /proc/*/maps
```

Narrow it to the library that was actually patched, map each pid back to the
unit that owns it (`/proc/<pid>/cgroup` ends in the unit name), restart exactly
those units, and the scan comes back empty. A service that is running but never
loaded the library has no stale mapping and does not need touching. Restarting
it would be harmless busywork; the point of the scan is to do neither too little
nor too much.

## Why this is the whole job

`needrestart` — the tool Debian runs for you after `apt upgrade` — is exactly
this scan, dressed up: it walks `/proc/*/maps`, finds processes running deleted
or outdated code, maps them to services, and offers to restart them. Running it
by hand once is worth more than trusting it a hundred times, because the day it
matters is the day it is not there: a container with no `needrestart`, a service
it does not recognize, a library in `/opt` it was never taught about. The signal
underneath it — a `(deleted)` mapping is a process running unpatched code — is
the thing that transfers.

The mental correction this builds: "installed" and "running" are different
states, and a patch changes the first without the second. The vulnerability is
closed on disk and open in memory until you close the gap deliberately, on
exactly the processes that have it.

## Restart or reboot

A restart fixes anything that lives in a process: a library, an interpreter, a
daemon's own binary. It cannot fix the one thing no process restart reloads —
the kernel. A new kernel package puts a new image in `/boot`; the machine keeps
running the old one until it boots into the new one. The evidence is a version
mismatch:

```
$ uname -r               # the kernel that is running
$ ls /boot/vmlinuz-*     # the kernels that are installed
```

If the update installed a kernel newer than the one `uname -r` reports, that
update — and only that update — is waiting on a reboot. Everything else from the
same transaction is either a restart (something running maps it) or nothing at
all (nothing running uses it). So the reboot is not "apply everything and reboot
on Friday"; it is one named package, scheduled deliberately, while the rest is
already live.

On Debian, the `unattended-upgrades` package drops a hook that touches
`/run/reboot-required` when a kernel is installed; Ubuntu does the same through
`update-notifier`. Useful, but it is a flag someone else computed. The version
comparison is the evidence it is computed from.

One honest caveat about this sandbox: it is a container, and a container has no
kernel of its own — `uname -r` shows the host's. The images in `/boot` here are
placeholders standing in for a real machine's. The reasoning is identical on a
VM or bare metal; the reboot is the part you cannot perform here.

## Unattended, but only security

Doing this by hand every night does not scale, which is what
`unattended-upgrades` is for. Its policy is ordinary apt configuration in
`/etc/apt/apt.conf.d/`, and two parts of it matter here.

**What it may install.** `Unattended-Upgrade::Origins-Pattern` lists the archives
it is allowed to take from. Debian's shipped file allows the security archive —
and also `label=Debian`, the stable point-release archive. That second line
means ordinary bug-fix releases land unattended too. For a service that cannot
take surprise changes, every allowed origin should be a security one.

**Whether it runs, and what it does afterwards.**
`APT::Periodic::Unattended-Upgrade "1"` is the daily trigger; without it the
policy is never acted on. `Unattended-Upgrade::Automatic-Reboot` decides whether
the box reboots itself when a kernel arrives; for this service it stays off, and
the reboot is planned.

Read it back through apt's own parser rather than trusting the file you edited —
`apt-config dump` is the merged view of every file in the directory, exactly as
unattended-upgrades will see it:

```
$ apt-config dump | grep -iE 'unattended|periodic'
```

(This offline sandbox does not have the unattended-upgrades package installed.
The policy is still apt configuration, and it is read and graded through
`apt-config`.)

"Security only" is the minimum, not the whole policy. In March 2023 Datadog lost
service across several regions when unattended-upgrades applied a systemd
security update to its Ubuntu hosts at the same time everywhere; the upgrade
restarted `systemd-networkd`, which flushed the network routes that Cilium, their
Kubernetes networking agent, had installed, and the nodes dropped off the
network. A security fix, correctly allowed, restarted a daemon whose restart had
side effects nobody had listed. That is what `Unattended-Upgrade::Package-Blacklist`
and a staged rollout are for: the packages whose restart you need to schedule
yourself are held back from the unattended run, and nothing updates the whole
fleet in the same minute.

## Checking yourself

```
$ grep -l 'libwidget.*(deleted)' /proc/*/maps
$          # (no output — nothing is running the old library)
$ systemctl is-active <each unit you restarted>
active                   # one line per unit
```

```
$ apt-config dump | grep -iE 'origins-pattern::|periodic::unattended|automatic-reboot'
```

No stale mappings, the services that needed restarting are back up on the
patched library, every allowed origin is a security one, the daily trigger is
set, and automatic reboot is not on.

<details>
<summary>Solution</summary>

```bash
# Find every process still mapping the pre-patch library, restart their services.
for p in $(grep -l 'libwidget.*(deleted)' /proc/*/maps 2>/dev/null); do
  pid=$(basename "$(dirname "$p")")
  unit=$(grep -oE '[a-z-]+\.service' /proc/$pid/cgroup | tail -1)
  echo "$unit"
done | sort -u | xargs -r sudo systemctl restart
```

Or, having identified them, simply:

```bash
sudo systemctl restart widget.service cache.service
```

The unattended policy:

```bash
sudo tee /etc/apt/apt.conf.d/50unattended-upgrades <<'CONF'
Unattended-Upgrade::Origins-Pattern {
        "origin=Debian,codename=${distro_codename},label=Debian-Security";
        "origin=Debian,codename=${distro_codename}-security,label=Debian-Security";
};
Unattended-Upgrade::Automatic-Reboot "false";
CONF
sudo tee /etc/apt/apt.conf.d/20auto-upgrades <<'CONF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
CONF
```

The kernel is the one update left waiting: the transaction installed
`linux-image-6.12.57+deb13-amd64`, and `uname -r` reports something else.

```
stale_library: libwidget.so.1
found_with: (deleted)
reboot_required: linux-image-6.12.57+deb13-amd64
```

</details>
