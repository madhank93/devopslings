---
title: "after hardening, the server serves fine and cannot fetch anything"
---

## The situation

`web1` went through the CIS hardening pass yesterday. Its firewall now denies
all inbound traffic except SSH and HTTP:

```
$ cat /etc/web1/rules.v4
*filter
:INPUT DROP [0:0]
:FORWARD DROP [0:0]
:OUTPUT ACCEPT [0:0]
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
COMMIT
```

The site is fine. Every deploy since has failed, because the deploy runs on
`web1`, pulls from the package mirror, and pushes to the artifact store:

```
$ ip netns exec web1 curl -s -m 5 http://10.89.0.1:8081/ ; echo $?
28
```

OUTPUT is ACCEPT, so nothing is stopping `web1` from sending.

## Your objective

Make `web1` able to reach the mirror (`:8081`) and the artifact store
(`:8082`), and keep it working after a reboot. Inbound stays default-deny, and
`web1`'s debug endpoint (`:6060`) and the forgotten dev server (`:41000`) stay
unreachable.

## What you're being graded on

`web1` reaches both services. INPUT's policy is still DROP. `:6060` and
`:41000` don't answer from outside, even to a connection that uses source port
8081. `/etc/web1/rules.v4` boots into the same thing.

<details>
<summary>Hint 1: a connection is two directions</summary>

`web1`'s SYN leaves through OUTPUT, which accepts it. The mirror answers with a
SYN-ACK, and that's a packet *arriving* at `web1`. To `web1`'s firewall it's
inbound like any other packet, from `10.89.0.1` port 8081 to some high port on
`web1`. Which rule accepts that?

```
$ ip netns exec web1 iptables -L INPUT -v -n
Chain INPUT (policy DROP 4 packets, 240 bytes)
```

</details>

<details>
<summary>Hint 2: the kernel already knows</summary>

Netfilter tracks connections (the conntrack table from earlier in this module).
When `web1` sends that SYN, the kernel records the flow, and the SYN-ACK coming
back is recognised as part of it: state `ESTABLISHED`. A firewall can match on
that:

```
-m conntrack --ctstate ESTABLISHED,RELATED
```

</details>

## Why "deny inbound" denied outbound too

A stateless rule list reads each packet alone. "Allow 22 and 80 in, drop the
rest" is correct for connections *to* `web1`. Every connection `web1` makes has
replies too, and those arrive addressed to a random ephemeral port, which no
rule mentions. The policy drops them. From `web1`'s side it looks like the
mirror never answers.

Almost every real default-deny ruleset starts with the same two lines, `lo` and
`ESTABLISHED,RELATED`, for exactly this reason. The hardening pass copied the
deny and missed the second one.

## The fix

<details>
<summary>Solution</summary>

Accept what conntrack already ties to a connection, near the top, in the boot
file:

```
-A INPUT -i lo -j ACCEPT
-A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A INPUT -p tcp -m tcp --dport 22 -j ACCEPT
-A INPUT -p tcp -m tcp --dport 80 -j ACCEPT
```

```
$ systemctl reload web1-firewall.service
$ ip netns exec web1 curl -s http://10.89.0.1:8081/
mirror-package-2026
```

It's near the top for performance as well as correctness: almost every packet
on a busy server belongs to an existing connection, so it should be matched
first.

</details>

## What not to do

**`iptables -P INPUT ACCEPT`.** The deploy works because the hardening is gone.

**Accept everything from `10.89.0.1`.** That's the mirror's address, and also
the address of everything else on that box, which can now reach `:6060`.

**Accept `--sport 8081`.** It looks like "allow the mirror's replies". What it
actually allows is any packet *from* port 8081, and the sender chooses its own
source port. `nc -p 8081` reaches the debug endpoint. It's the classic stateless
hole.

**Open the ephemeral range, `--dport 32768:60999`.** Replies land there, and so
does `:41000`, the dev server nobody remembers starting.

## Carrying this forward

On any default-deny policy, check the first rules before anything else: `lo`
and `ESTABLISHED,RELATED`. If a host can serve but can't fetch, look for the
policy counter on INPUT climbing every time it tries.
