---
title: "drop the web server from root to nobody, and keep it on port 80"
---

## The situation

`webportal.service` serves the customer portal, and it runs as root:

```
$ systemctl show -p MainPID --value webportal.service
1042
$ ps -o user= -p 1042
root
```

There is exactly one reason it is root: it listens on port 80, and ports below
1024 are privileged — the kernel only lets a process bind them if it is root or
holds the `CAP_NET_BIND_SERVICE` capability. So the portal binds its port once,
at startup, and then keeps root's full authority for the entire time it is
parsing requests from the internet. The bind takes a millisecond; the exposure
lasts as long as the process does.

That trade is backwards. A program that touches untrusted input should have the
least privilege that still lets it do its job — and its job needs precisely one
privileged operation, done once.

## Why the one-line fix breaks it

The instinct is right: drop the user.

```
[Service]
User=www-data
```

Restart, and the service is dead:

```
$ systemctl status webportal
   Active: failed (Result: exit-code)
$ journalctl -u webportal -n2
   OSError: [Errno 13] Permission denied
```

www-data is not root, so it cannot bind port 80, so the server never starts. You
have removed the privilege *and* the capability that depended on it. Dropping the
user is necessary and not sufficient: you also have to hand back the single
privileged operation the service legitimately needs.

## Grant one capability, not root

Linux splits root's power into capabilities — distinct, individually grantable
privileges. Binding a low port is one of them: `CAP_NET_BIND_SERVICE`. systemd
can give a service exactly that and nothing else:

```
[Service]
User=www-data
Group=www-data
NoNewPrivileges=yes

AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
```

Three things are happening, and each matters:

**`AmbientCapabilities=CAP_NET_BIND_SERVICE`** puts that one capability into the
process's *ambient* set, which is what a process actually carries across an
`execve`. This is the capability that lets www-data bind port 80. It is the
replacement for root — the specific power, without the rest of it.

**`CapabilityBoundingSet=CAP_NET_BIND_SERVICE`** sets a ceiling: this is the
maximum the process may ever hold, so even a full compromise of the portal
cannot acquire `CAP_DAC_OVERRIDE` or `CAP_SETUID` or any other capability. The
ambient set says what it has; the bounding set says what it could ever have.

**`NoNewPrivileges=yes`** slams a one-way door: the process and everything it
spawns can never gain privilege again — no setuid binary, no filesystem
capability, nothing elevates. It is what makes the reduced privilege *stick*
rather than being a starting point the process can climb out of.

Together they invert the original trade: the portal binds its port, and then
runs as an ordinary user who cannot become anyone else, holding one narrow
capability it needs and provably nothing more.

## Reading it back from the kernel

The unit file states intent; `/proc/<pid>/status` states reality. It is worth
confirming the process is running the way the file claims:

```
$ pid=$(systemctl show -p MainPID --value webportal.service)
$ grep -E 'NoNewPrivs|CapAmb|CapBnd' /proc/$pid/status
NoNewPrivs:  1
CapAmb:      0000000000000400
CapBnd:      0000000000000400
```

`0x400` is bit 10, and bit 10 is `CAP_NET_BIND_SERVICE`. The ambient set holds
it (so the bind works), the bounding set is capped to it (so nothing else is
reachable), and `NoNewPrivs: 1` confirms the door is shut. A hardened service is
not what the unit file says; it is what these three lines say.

<details>
<summary>Hint 1 — the naive drop and why it fails</summary>

Adding `User=www-data` alone makes the service fail with `Permission denied` on
the bind. A non-root process cannot open port 80 unless it is granted the
capability for it. You need the user drop *and* the capability.

</details>

<details>
<summary>Hint 2 — the two capability directives</summary>

```
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
```

`AmbientCapabilities` grants it; `CapabilityBoundingSet` ensures the service can
never hold more than that one. Add `NoNewPrivileges=yes` so privilege can never
be regained.

</details>

<details>
<summary>Hint 3 — reload the unit definition, then restart</summary>

Changing a unit file needs `systemctl daemon-reload` before the change is seen,
then `systemctl restart webportal`. Confirm with:

```
$ curl -s http://127.0.0.1/          # portal up
$ ps -o user= -p $(systemctl show -p MainPID --value webportal)   # www-data
```

</details>

## Checking yourself

```
$ curl -s http://127.0.0.1/
portal up
$ pid=$(systemctl show -p MainPID --value webportal.service)
$ ps -o user= -p $pid ; grep NoNewPrivs /proc/$pid/status
www-data
NoNewPrivs:  1
```

Still serving, as www-data, unable to climb back up.

<details>
<summary>Solution</summary>

Edit `/etc/systemd/system/webportal.service` so the `[Service]` section reads:

```
[Service]
ExecStart=/usr/bin/python3 /opt/webportal.py
Restart=on-failure
User=www-data
Group=www-data
NoNewPrivileges=yes
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
```

```bash
sudo systemctl daemon-reload
sudo systemctl restart webportal.service
```

```
run_as: www-data
no_new_privileges: yes
bind_capability: CAP_NET_BIND_SERVICE
```

</details>
