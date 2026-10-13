---
title: "iptables says the port is allowed, and the port is blocked"
---

## The situation

This box is the new load balancer for the API tier. It can't reach `api1`:

```
$ curl -s -m 5 http://10.90.0.10:8080/ ; echo $?
28
```

`api1`'s firewall was migrated to a managed ruleset last month. The ruleset
allows exactly this traffic, and the live tables agree:

```
$ ip netns exec api1 iptables -L INPUT -n
# Warning: iptables-legacy tables present, use iptables-legacy to see them
Chain INPUT (policy DROP)
target     prot opt source         destination
ACCEPT     all  --  0.0.0.0/0      0.0.0.0/0
ACCEPT     all  --  0.0.0.0/0      0.0.0.0/0     ctstate RELATED,ESTABLISHED
ACCEPT     tcp  --  0.0.0.0/0      0.0.0.0/0     tcp dpt:22
ACCEPT     tcp  --  10.90.0.0/24   0.0.0.0/0     tcp dpt:8080
```

## Your objective

Make the API reachable from this box and keep it that way after a reboot. The
managed ruleset is the firewall of record, so keep it, default-deny included.
The metrics port (`:9090`) stays unreachable.

## What you're being graded on

The load balancer reaches `:8080`. `:9090` stays shut and INPUT stays at DROP
in the managed ruleset. The legacy tables are empty, and nothing re-fills them
at boot.

<details>
<summary>Hint 1: read the first line</summary>

Most people skip it because it doesn't look like a rule:

```
# Warning: iptables-legacy tables present, use iptables-legacy to see them
```

```
$ ip netns exec api1 iptables-legacy -L INPUT -v -n
```

</details>

<details>
<summary>Hint 2: who loads it?</summary>

```
$ systemctl list-unit-files | grep api1
$ systemctl cat api1-legacy-fw.service
```

</details>

## Why two firewalls both win

The `iptables` command has two backends. **iptables-legacy** writes into the
kernel's original x_tables. **iptables-nft**, Debian's default `iptables`,
translates the same syntax into nftables. Both register their own hooks in the
same places in the packet path, and a packet has to get past **every** hook
registered there.

So the nft ruleset's ACCEPT says "this firewall has no objection", and then the
packet meets the legacy table's DROP. The ACCEPT doesn't stop it there, because
it was never the only rule set.

`iptables -L` shows only one of them, the nft backend's. Its only mention of the
other is a comment line above the output.

## The fix

<details>
<summary>Solution</summary>

Stop the old script from running at boot, then empty the table it filled:

```
$ systemctl disable --now api1-legacy-fw.service
$ ip netns exec api1 iptables-legacy -F INPUT
$ ip netns exec api1 iptables-legacy-save | grep -c '^-A'
0
$ curl -s http://10.90.0.10:8080/
api-answers-2026
```

The legacy rule's intent, "only the load balancers", is already in the managed
ruleset as `-s 10.90.0.0/24`. Nothing needs carrying over.

</details>

## What not to do

**Insert an ACCEPT at the top of the nft ruleset.** It changes nothing. The
packet still meets the legacy DROP.

**Add an ACCEPT to the legacy table, or update the old script's subnet.** It
works, and the host still runs two firewalls, one invisible to the tool everyone
uses. The next incident on this host starts with the same confusion.

**Flush the legacy table and stop.** The script is still enabled, so it
re-creates the table at the next boot.

**Flush everything and set ACCEPT.** The API works, and so does `:9090`.

## Carrying this forward

When the rules you can see allow something and it's still blocked, ask how many
rule sets there are before reading any of them. `iptables-legacy-save`,
`iptables-nft-save` and `nft list ruleset` together show every table on the
box. The legacy tables also appear when Docker, a VPN client or an old
configuration-management role still uses `iptables-legacy`.
