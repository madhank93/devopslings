---
title: "the tuning that works until something re-reads the config"
---

## The situation

edge-proxy needs `net.ipv4.tcp_keepalive_time` at 120, so a dead peer is
noticed before the load balancer gives up on the connection. Somebody has
already written that down:

```
$ cat /etc/sysctl.d/10-edge-proxy.conf
# Shorter keepalive so dead peers are noticed before the LB gives up.
net.ipv4.tcp_keepalive_time = 120

$ cat /proc/sys/net/ipv4/tcp_keepalive_time
7200
```

The file says 120. The kernel says 7200. The file is being read — it is in the
right directory with the right syntax — and the value is still the default.

## Your objectives

| file | answer |
|---|---|
| `/root/answers/override` | the full path of the file overriding it |

Then make 120 the value actually in effect, and make it stay that way when the
sysctl configuration is applied again.

## What you're being graded on

The overriding file named correctly, the running value at 120, the value still
at 120 after the configuration is re-applied the way a boot does, and a file on
disk that sets it — a live `sysctl -w` does not count.

<details>
<summary>Hint 1 — watch the configuration being applied</summary>

```
$ sysctl --system
* Applying /usr/lib/sysctl.d/50-default.conf ...
* Applying /etc/sysctl.d/10-edge-proxy.conf ...
net.ipv4.tcp_keepalive_time = 120
* Applying /etc/sysctl.d/99-vendor-net.conf ...
net.ipv4.tcp_keepalive_time = 7200
* Applying /etc/sysctl.conf ...
```

There it is, in order. Your file is applied. Then another one is applied after
it and sets the same key.

Files from `/etc/sysctl.d`, `/run/sysctl.d` and `/usr/lib/sysctl.d` are merged
and processed in **lexicographic order by filename**, and each `key = value` is
a write to the running kernel. The last write wins. `10-` sorts before `99-`.

This is the same drop-in precedence as systemd units, `sudoers.d`, and
`journald.conf.d` — worth learning once.

</details>

<details>
<summary>Hint 2 — why `sysctl -w` is not the fix</summary>

```
$ sysctl -w net.ipv4.tcp_keepalive_time=120
net.ipv4.tcp_keepalive_time = 120
```

Correct, immediately, and gone at the next boot — or the next time anything runs
`sysctl --system`, which is a config-management run, a package postinst, or a
`systemd-sysctl` restart.

The check re-applies the configuration deliberately, because that is the event
that separates "I changed the running kernel" from "I changed what the machine
does".

Two different actions, and people routinely do the first believing they did the
second:

| | changes now | survives |
|---|---|---|
| `sysctl -w key=value` | yes | no |
| a file in `/etc/sysctl.d/` | no, until applied | yes |

You want both: write the file, then apply it.

</details>

<details>
<summary>Hint 3 — where to put yours</summary>

The vendor file says not to edit it, and it is right — a package upgrade
replaces it and takes your change with it. Add a file that sorts *after* it:

```
$ cat > /etc/sysctl.d/99-zz-edge-proxy.conf <<'CONF'
net.ipv4.tcp_keepalive_time = 120
CONF
$ systemctl restart systemd-sysctl.service
$ cat /proc/sys/net/ipv4/tcp_keepalive_time
120
```

And delete `10-edge-proxy.conf`. It is applied and then overwritten, so leaving
it there tells the next person the setting is handled when it is not — a file
that looks like the answer and is not is worse than no file.

</details>

<details>
<summary>Solution</summary>

```
$ echo /etc/sysctl.d/99-vendor-net.conf > /root/answers/override

$ cat > /etc/sysctl.d/99-zz-edge-proxy.conf <<'CONF'
# Overrides the keepalive in 99-vendor-net.conf. Named to sort last: sysctl
# applies files in lexicographic order and the final write to a key wins.
net.ipv4.tcp_keepalive_time = 120
CONF

$ rm /etc/sysctl.d/10-edge-proxy.conf
$ systemctl restart systemd-sysctl.service
```

### Why this is a lesson at all

Nothing here is broken and nothing is hidden. The file exists, is syntactically
correct, is in the right directory, and is genuinely applied. It is simply
applied *before* another file that sets the same key, and there is no warning
about that anywhere — `sysctl --system` reports both writes as successes,
because both are.

Three things worth keeping:

1. **"Configured" and "in effect" are different claims.** Check the running
   value, not the file you wrote. `/proc/sys/...`, `sysctl -n <key>` — one
   command, and it is the only one that answers the question you actually have.

2. **Drop-in directories are ordered, and last wins.** Adding a file is not the
   same as making a change. The same trap catches people in `sysctl.d`,
   `sudoers.d`, `systemd` drop-ins, `logrotate.d`, nginx `conf.d` and
   `journald.conf.d` — and in every one of them the tool that shows you the
   merged result (`sysctl --system`, `systemctl cat`, `nginx -T`) is the thing
   to reach for rather than the file you edited.

3. **Delete the attempt that did not work.** A file expressing the right
   intention and having no effect is a trap for whoever reads it next, and they
   will reasonably conclude the setting is already handled.

A note on scope: this lesson uses a `net.*` sysctl deliberately. Network sysctls
are per-network-namespace, so this container genuinely has its own. `vm.*` and
`kernel.*` are shared with the host, and changing them from inside a container
changes them for the whole machine — which is why nothing in this course writes
to them.

</details>
