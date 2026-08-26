---
title: "the library is patched on disk and still running in memory"
---

## The situation

The security update landed. The file on disk is the fixed version:

```
$ ls -l /opt/patchlab/libwidget.so.1
-rw-r--r-- 1 root root 133600 Aug 26 10:02 /opt/patchlab/libwidget.so.1
```

And the box is still vulnerable.

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

Narrow it to the library that was actually patched, and map each pid back to its
service:

```
$ for p in $(grep -l 'libwidget.*(deleted)' /proc/*/maps 2>/dev/null); do
    pid=$(basename $(dirname $p))
    echo "$pid $(grep -oE '[a-z-]+\.service' /proc/$pid/cgroup | tail -1)"
  done
1042 widget.service
1043 cache.service
```

Two services, not the whole box. Restart exactly those:

```
$ sudo systemctl restart widget.service cache.service
```

and the scan comes back empty. The third service on the box, `metrics`, is
running but never loaded the library, so it has no stale mapping and does not
need touching. Restarting it would be harmless busywork; the point of the scan
is to do neither too little nor too much.

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
<summary>Hint 2 — pid to service</summary>

```
$ cat /proc/<pid>/cgroup
```

The line ends in `<name>.service`. That is the unit to restart.

</details>

<details>
<summary>Hint 3 — restart only those</summary>

```
$ sudo systemctl restart widget.service cache.service
```

Two services are affected. The third is running but never loaded the library —
leave it. Do not reboot.

</details>

## Checking yourself

```
$ grep -l 'libwidget.*(deleted)' /proc/*/maps
$          # (no output — nothing is running the old library)
$ systemctl is-active widget.service cache.service
active
active
```

No stale mappings, and the two services that needed restarting are back up on
the patched library.

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

```
stale_library: libwidget.so.1
found_with: (deleted)
```

</details>
