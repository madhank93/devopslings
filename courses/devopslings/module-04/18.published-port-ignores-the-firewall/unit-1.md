---
title: "the host firewall allows SSH only, and the container's admin UI is on the internet"
---

## The situation

`dock1` is a Docker host. Its firewall denies all inbound traffic except SSH,
and that policy is in place:

```
$ ip netns exec dock1 iptables -L INPUT -v -n
Chain INPUT (policy DROP 0 packets, 0 bytes)
    0     0 ACCEPT  all  --  lo  *  0.0.0.0/0  0.0.0.0/0
    0     0 ACCEPT  all  --  *   *  0.0.0.0/0  0.0.0.0/0   ctstate RELATED,ESTABLISHED
    0     0 ACCEPT  tcp  --  *   *  0.0.0.0/0  0.0.0.0/0   tcp dpt:22
```

A pentest reached the admin UI of a container on it, from the internet, on the
published port:

```
$ curl -s http://10.91.0.10:8080/
admin-ui-2026
```

Every counter on INPUT is zero. Not one of the pentester's packets was refused,
or even checked.

## Your objective

The admin UI is for the office only, from the VPN concentrator at
`10.91.0.50`. Make that true, and keep it true when dockerd restarts and when
`dock1` reboots. The grader does both before checking. The container keeps its
published port, and dockerd (`/usr/local/sbin/dockerd-sim`) isn't yours to
edit.

## What you're being graded on

After the host firewall is reloaded from `/etc/dock1/rules.v4` and dockerd is
started, `10.91.0.50` reaches the UI and two different outside addresses don't.

<details>
<summary>Hint 1: where does the packet go first?</summary>

```
$ ip netns exec dock1 iptables -t nat -L PREROUTING -v -n
    2   120 DOCKER  all  --  *  *  0.0.0.0/0  0.0.0.0/0   ADDRTYPE match dst-type LOCAL
$ ip netns exec dock1 iptables -t nat -L DOCKER -n
DNAT  tcp  --  0.0.0.0/0  0.0.0.0/0   tcp dpt:8080 to:172.18.0.2:80
```

PREROUTING runs **before** the routing decision. By the time the kernel decides
between INPUT and FORWARD, the destination is no longer `dock1:8080` but
`172.18.0.2:80`, a container behind a bridge. Which chain is that?

</details>

<details>
<summary>Hint 2: Docker's FORWARD</summary>

```
$ ip netns exec dock1 iptables -L FORWARD -v -n
Chain FORWARD (policy DROP)
   25  1888 DOCKER-USER     all  --  *  *  0.0.0.0/0  0.0.0.0/0
   25  1888 DOCKER-FORWARD  all  --  *  *  0.0.0.0/0  0.0.0.0/0
```

dockerd rebuilds DOCKER and DOCKER-FORWARD every time it starts, and puts its
jumps at the top of FORWARD. It creates DOCKER-USER and then never touches it
again. The chain exists for your rules, and it's evaluated first.

</details>

<details>
<summary>Hint 3: which port is it by then?</summary>

In FORWARD, the packet has already been translated, so `--dport 8080` matches
nothing. Either match what it became (`-d 172.18.0.2 --dport 80`), or ask
conntrack what it was originally addressed to:

```
-m conntrack --ctorigdstport 8080
```

</details>

## Why the firewall never saw it

A published port is DNAT. Docker rewrites the destination in `nat PREROUTING`,
and the packet is then routed to the container, so it's *forwarded*. It never
goes up to INPUT. The host firewall was guarding the host, correctly. The
container was reached through a door the host firewall doesn't cover, and
Docker opened it on purpose: `-p 8080:80` means "publish this to every address
on the host".

This is the same lesson as the wrong-chain exercise, with one more twist: the
translation happens before the filtering. ufw, firewalld and hand-written
rulesets all have the same blind spot on a Docker host, for the same reason.

## The fix

<details>
<summary>Solution</summary>

Filter in DOCKER-USER, in the file that loads before dockerd starts:

```
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
:DOCKER-USER - [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT
-A DOCKER-USER -s 10.91.0.50/32 -j RETURN
-A DOCKER-USER -i eth0 -p tcp -m conntrack --ctorigdstport 8080 --ctstate NEW -j DROP
COMMIT
```

```
$ systemctl restart dock1-firewall.service dock1-dockerd.service
$ curl -s -m 3 http://10.91.0.10:8080/ ; echo $?
28
$ ip netns exec office2 curl -s http://10.91.0.10:8080/
admin-ui-2026
```

`RETURN` hands the office's packets back to FORWARD, where Docker's chains accept
them. Everything else arriving on `eth0` for the original port 8080 is dropped
before Docker's chains see it.

The other real fix is to publish only where it's needed:
`-p 10.0.0.5:8080:80` binds the published port to one host address instead of
all of them.

</details>

## What not to do

**DROP 8080 in INPUT.** The counter never moves, because nothing for that port
goes through INPUT.

**`--dport 8080` in DOCKER-USER.** It's the right chain with the wrong port,
because the packet was translated before it got there.

**Append to FORWARD.** Docker's jumps sit above it and accept the packet first.
On the next dockerd start, Docker reinserts its jumps above yours again.

**Delete Docker's DNAT or ACCEPT rule.** It's gone until dockerd restarts.

**Block `10.91.0.1`.** That's one attacker. "Only the office" is an allow-list,
not a block-list.

## Carrying this forward

On a container host, the host firewall's INPUT chain protects the host. It
doesn't protect the containers. Published ports are DNAT plus FORWARD. Before
trusting "the firewall", list `-t nat` and FORWARD as well as INPUT, and put
your container rules in DOCKER-USER, where dockerd will leave them alone.
