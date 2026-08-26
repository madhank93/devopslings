---
title: "the brute-force jail is about to ban the load balancer"
---

## The situation

fail2ban is watching for SSH brute-force, and it is about to succeed at exactly
the wrong thing. Look at what it sees:

```
$ fail2ban-regex /var/log/auth.log sshd
...
Lines: 12 lines, 0 ignored, 12 matched, 0 missed
```

Twelve failed logins, all matched by the sshd filter. Now look at where they
came from:

```
$ grep -oE 'from [0-9.]+' /var/log/auth.log | sort | uniq -c
     12 from 10.9.0.9
```

Every single one from `10.9.0.9`. The jail's `maxretry` is 5, so five failures
from one address is a ban — and this address has twelve. The moment the jail
runs, `10.9.0.9` is banned.

`10.9.0.9` is the load balancer. Every SSH session on this box arrives through
it, so from the box's point of view every connection — and every failed login —
comes from that one address. Ban it and you have not blocked an attacker; you
have blocked the single door every legitimate user comes through. The site goes
dark, and fail2ban's own log will proudly say it stopped a brute-force attack.

## Why every attacker looks like one IP

This is the same fact as the `real-ip` lesson in the proxy module, seen from the
security side. A proxy or load balancer terminates the client's connection and
opens its own to the backend, so the backend sees the *proxy's* address as the
source. The real client's address is carried separately — in an
`X-Forwarded-For` header for HTTP, or via PROXY protocol for raw TCP — and
`sshd` writing to `auth.log` records the address it actually received the
connection from, which is the load balancer.

So a per-source-IP rule like fail2ban's counts every client's failures against
the proxy. One fumbled password from each of a hundred users, and the proxy
crosses `maxretry` in seconds. The mechanism that is supposed to isolate one bad
actor instead aggregates everyone into a single one, and bans the thing they
have in common.

## The immediate fix: exempt the load balancer

fail2ban has a directive for "never ban this, whatever it does": `ignoreip`. Add
the load balancer to the sshd jail:

```
[sshd]
enabled  = true
logpath  = /var/log/auth.log
maxretry = 5
ignoreip = 127.0.0.1/8 10.9.0.9
```

Validate the change the same way you would any jail edit — a config fail2ban
cannot parse is one it will not load, leaving you with no protection at all:

```
$ fail2ban-client -t
OK: configuration test is successful
$ fail2ban-client -d | grep -i ignoreip
['set', 'sshd', 'addignoreip', '127.0.0.1/8', '10.9.0.9']
```

`fail2ban-client -d` prints the *parsed* configuration — what fail2ban would
actually load, with every include and default resolved — so it is the honest
check that the ignore actually took, not just that a line is present in a file.

## What ignoreip does and does not fix

Exempting the load balancer stops the outage, and it is the right first move. Be
clear about what it costs, though: now that the one visible source is ignored,
fail2ban sees failed logins from `10.9.0.9` and ignores every one of them —
including the real brute-force attempts, which also arrive from `10.9.0.9`. The
jail is still running, but against this log it can no longer ban anyone. You have
traded a jail that bans everyone for a jail that bans no one.

The real fix is upstream: get the client's true address into the log the jail
reads, so failures are counted per actual client again. That means the load
balancer passing the source address through — PROXY protocol to sshd, or a
forwarded-for field the filter can be pointed at — and a `failregex` that reads
the client address rather than the connection's. Then `ignoreip` on the load
balancer is still correct (the LB's own address should never be banned) but it no
longer blinds the jail, because the addresses being counted are the clients'
again.

`ignoreip` is the incident response — it stops the site going down in the next
five minutes. Fixing the logged source address is the actual repair. A jail that
cannot see who its clients are is not protecting them; it is just deciding
whether to ban all of them or none.

<details>
<summary>Hint 1 — see what fail2ban sees</summary>

```
$ fail2ban-regex /var/log/auth.log sshd
$ grep -oE 'from [0-9.]+' /var/log/auth.log | sort | uniq -c
```

All the failures share one source address. That address is the load balancer,
not an attacker.

</details>

<details>
<summary>Hint 2 — the ignore directive</summary>

Add the load balancer's address to `ignoreip` in the `[sshd]` jail:

```
ignoreip = 127.0.0.1/8 10.9.0.9
```

Do not disable the jail — real attackers still need catching once the logs carry
their real addresses.

</details>

<details>
<summary>Hint 3 — validate the parsed config</summary>

```
$ fail2ban-client -t
$ fail2ban-client -d | grep -i ignoreip
```

`-t` confirms the file parses; `-d` shows the effective ignore list fail2ban
would load.

</details>

## Checking yourself

```
$ fail2ban-client -t
OK: configuration test is successful
$ fail2ban-client -d | grep addignoreip
['set', 'sshd', 'addignoreip', '127.0.0.1/8', '10.9.0.9']
```

The jail is still enabled, and the load balancer is exempt from it.

<details>
<summary>Solution</summary>

Add `ignoreip` to the sshd jail in `/etc/fail2ban/jail.local`:

```
[DEFAULT]
backend = polling

[sshd]
enabled  = true
logpath  = /var/log/auth.log
maxretry = 5
findtime = 600
bantime  = 3600
ignoreip = 127.0.0.1/8 10.9.0.9
```

```bash
sudo fail2ban-client -t
```

```
wrongly_banned_ip: 10.9.0.9
fixed_with: ignoreip
```

</details>
