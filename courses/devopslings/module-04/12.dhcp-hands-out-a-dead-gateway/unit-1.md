---
title: "the new server got an address and cannot reach anything past its own subnet"
---

## The situation

`web3` was provisioned on `lan2` this morning. It booted, ran DHCP, and got an
address. It can reach its router, which is this box:

```
$ ip netns exec web3 ip -br addr show eth0
eth0@if48   UP   10.60.0.152/24
$ ip netns exec web3 ping -c1 10.60.0.1
1 packets transmitted, 1 received, 0% packet loss
```

It can't reach anything one hop further:

```
$ ip netns exec web3 ping -c1 -W2 172.31.0.11
1 packets transmitted, 0 received, 100% packet loss
```

This box runs the DHCP server for `lan2`, and its config names the router in
plain sight:

```
$ cat /etc/lan-dhcp/conf.d/10-lan2.conf
# lan2 — 10.60.0.0/24. Gateway is this box.
dhcp-range=10.60.0.100,10.60.0.199,255.255.255.0,12h
dhcp-option=option:router,10.60.0.1
```

Forwarding is on and NAT for `lan2` is in place. Somewhere between that file and
`web3`, `10.60.0.1` became something else.

## Your objective

Make `web3` reach `172.31.0.11`, and make sure the next server provisioned on
`lan2` gets a working lease too. `10.60.0.254` was the old core switch. It's
reserved for that switch's replacement, so don't bring it back on this box.

## What you're being graded on

A brand-new client on `lan2` is offered `10.60.0.1` as its router. `web3`'s
default route is `via 10.60.0.1` and was put there by DHCP, not by hand.
`web3` reaches `172.31.0.11`, and this box doesn't hold `10.60.0.254`.

<details>
<summary>Hint 1: start from the client</summary>

DHCP gives a client more than an address. Every lease carries **options**: the
subnet mask, the lease time, the DNS servers, and option 3, the **router**. The
client's default route comes from that one option. Look at what `web3` was
given:

```
$ ip netns exec web3 ip route
default via 10.60.0.254 dev eth0 proto dhcp src 10.60.0.152 metric 1002
$ ip netns exec web3 ip neigh
10.60.0.254 dev eth0 INCOMPLETE
```

`proto dhcp` says the DHCP client installed the route. `INCOMPLETE` means
`web3` has been asking who has `10.60.0.254` and nobody answers.

</details>

<details>
<summary>Hint 2: the wire does not lie</summary>

The config is what someone wrote. The packet is what the server actually sent.
Watch a renewal:

```
$ tcpdump -vni lan2 port 67 &
$ ip netns exec web3 dhcpcd -4 -n eth0
    DHCP-Message (53), length 1: ACK
    Server-ID (54), length 4: 10.60.0.1
    Lease-Time (51), length 4: 43200
    Subnet-Mask (1), length 4: 255.255.255.0
    Default-Gateway (3), length 4: 10.60.0.254
```

The server is `10.60.0.1`, and it's offering a different gateway. So find
out what it read:

```
$ systemctl cat lan-dhcp.service
$ cat /etc/lan-dhcp/dnsmasq.conf
```

</details>

<details>
<summary>Hint 3: a directory of snippets is one file</summary>

`conf-dir=` makes dnsmasq read every `*.conf` in the directory, in name order,
as if they were pasted into one file. If two snippets set the same option,
dnsmasq keeps the last one it read.

```
$ grep -rn 'router\|option=3\|option:3' /etc/lan-dhcp/
```

</details>

## Why it looked right

Two files set the router option. `10-lan2.conf` says `10.60.0.1`.
`50-core-migration.conf`, a leftover from a migration that never finished,
says `10.60.0.254`. It's read second, so it wins. Anyone who opens "the lan2
config" sees the right answer and stops reading.

Everything else about the lease is correct, which is why the failure looks so
narrow. The address works, so does the subnet route, and `web3` can reach
anything on `lan2`. Only traffic that needs a router fails, and it fails
quietly. `web3` asks for the MAC of `10.60.0.254`, gets no reply, and drops the
packet.

Fixing the server isn't enough on its own, either. A client keeps a lease's
options until it renews, and it doesn't renew until T1, which is half the lease
time (here, about six hours). `web3` would carry the dead gateway until
lunchtime unless you ask it to renew now.

## The fix

<details>
<summary>Solution</summary>

Remove the stale snippet, restart the server so its offers change, and renew
the client so its lease does:

```
$ rm /etc/lan-dhcp/conf.d/50-core-migration.conf
$ systemctl restart lan-dhcp.service
$ ip netns exec web3 dhcpcd -4 -n eth0
$ ip netns exec web3 ip route show default
default via 10.60.0.1 dev eth0 proto dhcp src 10.60.0.152 metric 1002
$ ip netns exec web3 ping -c1 172.31.0.11
1 packets transmitted, 1 received, 0% packet loss
```

`systemctl restart web3-dhcp.service` works as a renew too, since a fresh
client asks from scratch.

</details>

## What not to do

**Set the default route on `web3` by hand.** `web3` works, until its next
renewal, which may put the DHCP route back. Every other server provisioned on
`lan2` still gets the dead gateway, and each one becomes its own ticket.

**Put `10.60.0.254` on this box.** The bad lease starts working because you've
made it true. The address is reserved for the switch's replacement, and on the
day that arrives `lan2` has two hosts answering ARP for one IP.

**Edit `10-lan2.conf`.** It was already right. Changing the file you were
looking at instead of the one that's in effect is the whole trap.

**Fix the config and stop.** dnsmasq reads its config once, at start. Until you
restart it, the running server keeps offering what it read this morning.

## Carrying this forward

When a host has an address and no way off its subnet, check the lease options
before anything else. Run `ip route` and look for `proto dhcp`, then
`tcpdump -vn port 67` to see what was actually offered. A DHCP problem is
rarely "no address". More often it's a perfectly good address with a bad
option attached.

When a service reads a directory of snippets, the effective config is all of
them together, in order. Reading only the snippet that looks relevant is how
a three-line override hides for months.
