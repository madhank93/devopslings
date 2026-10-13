---
title: "the VPN handshake is fresh, and the network behind it is unreachable"
---

## The situation

This box is the office gateway. A WireGuard tunnel, `wg0`, managed by
`wg-quick@wg0` from `/etc/wireguard/wg0.conf`, connects it to the datacenter,
where the application servers live on `10.87.0.0/24`. The tunnel looks healthy:

```
$ wg show
interface: wg0
  listening port: 51820

peer: m3uenTzcWn9QtEVJFswMPHq/2mMDp100yobN8xQclis=
  endpoint: 192.168.86.2:51820
  allowed ips: 10.86.0.2/32
  latest handshake: 41 seconds ago
  transfer: 1.21 KiB received, 1.40 KiB sent

$ ping -c1 10.86.0.2
64 bytes from 10.86.0.2: icmp_seq=1 ttl=64 time=0.31 ms
```

The servers behind it aren't reachable:

```
$ curl -s -m 5 http://10.87.0.10:8080/
$ echo $?
28
```

## Your objective

Make `10.87.0.10:8080` reachable from this box *through the tunnel*, and keep it
that way after `wg-quick@wg0` restarts. The datacenter end belongs to another
team, so read it but don't change it. Traffic to the datacenter stays inside the
tunnel, and nothing else gets pulled into it.

## What you're being graded on

`10.87.0.10` routes via `wg0` and serves the page. The datacenter peer isn't
allowed `0.0.0.0/0`, and the lab network still leaves by `eth0`.
`/etc/wireguard/wg0.conf` allows `10.87.0.0/24`.

<details>
<summary>Hint 1: start with the routing table</summary>

```
$ ip route get 10.87.0.10
10.87.0.10 via 172.31.0.1 dev eth0 src 172.31.0.10
$ ip route show dev wg0
10.86.0.0/24 proto kernel scope link src 10.86.0.1
```

Traffic for the datacenter's servers goes out the default route, away from the
tunnel. The only route on `wg0` is the tunnel's own subnet, and nobody wrote a
route for `10.87.0.0/24`. With wg-quick, nobody is supposed to: it derives the
routes from the config.

</details>

<details>
<summary>Hint 2: add the route anyway, and read the error</summary>

```
$ ip route add 10.87.0.0/24 dev wg0
$ ping -c1 10.87.0.10
From 10.86.0.1 icmp_seq=1 Destination Host Unreachable
ping: sendmsg: Required key not available
```

The packet reached `wg0`, and `wg0` refused it. "Required key not available"
means WireGuard couldn't find a peer to encrypt this packet for.

</details>

<details>
<summary>Hint 3: cryptokey routing</summary>

A WireGuard interface can have many peers, so it has to decide which one each
outgoing packet is for. It does that with `AllowedIPs`: a packet goes to the
peer whose `AllowedIPs` contains its destination address. If no peer's list
contains it, the packet is dropped.

The same list works in reverse as a filter on what comes in: a decrypted packet
from a peer is accepted only if its *source* is in that peer's `AllowedIPs`.

```
$ wg show wg0 allowed-ips
```

wg-quick also installs a route for each `AllowedIPs` entry, which is why
there's no route in Hint 1.

</details>

## Why the handshake proves so little

The handshake is between the two **endpoints**, `192.168.86.1` and
`192.168.86.2` on the underlay. It proves the keys match and UDP 51820 gets
through, and nothing about which addresses may use the tunnel once it's up.
The datacenter end sends a keepalive every 25 seconds, so the handshake always
looks fresh.

`10.86.0.2` answers because it's in the peer's `AllowedIPs` and covered by the
connected `10.86.0.0/24` route. `10.87.0.10` is in neither. In WireGuard,
"which peer is this for" and "may this address use the tunnel" are the same
question, answered by one line in the config. That line names only the far
end's tunnel address and forgets the network it's there to reach.

## The fix

<details>
<summary>Solution</summary>

Allow the datacenter's subnet for the datacenter peer, in the file, and let
wg-quick rebuild the interface and its routes:

```
[Peer]
# dc-gw01
PublicKey = ...
Endpoint = 192.168.86.2:51820
AllowedIPs = 10.86.0.2/32, 10.87.0.0/24
```

```
$ systemctl restart wg-quick@wg0.service
$ ip route get 10.87.0.10
10.87.0.10 dev wg0 src 10.86.0.1 uid 0
$ curl -s http://10.87.0.10:8080/
dc-app-answers-2026
```

The datacenter end needs nothing. It sees traffic from `10.86.0.1`, the office's
tunnel address, which it already allows.

</details>

## What not to do

**Add a route and stop.** The route gets the packet to `wg0`, but WireGuard has
no peer for it, so it's dropped with `ENOKEY`. Routes and `AllowedIPs` have to
agree, and wg-quick keeps them in step if you change the config instead of the
table.

**Route `10.87.0.0/24` via `192.168.86.2` on `to-dc`.** It works, because the
datacenter is reachable over the underlay. The traffic now crosses the internet
unencrypted, outside the VPN.

**`AllowedIPs = 0.0.0.0/0`.** Every destination now matches this peer, and
wg-quick takes `/0` as an instruction to route *all* the box's traffic into the
tunnel. That's right for a laptop's full-tunnel VPN and wrong for a
site-to-site link.

**`wg set wg0 peer ... allowed-ips ...` and stop.** It fixes the running
interface. `wg-quick@wg0` rebuilds `wg0` from the file on its next restart, and
the subnet disappears again.

## Carrying this forward

With WireGuard, `AllowedIPs` is the routing table inside the tunnel, as well as
its access list. When the handshake is fresh and some destinations don't work,
read `wg show <if> allowed-ips` before anything else, on *both* ends. The far
end must allow your source, and you must allow its destination.

"The tunnel is up" and "the tunnel carries this traffic" are separate claims,
just as "the BGP session is established" and "the route is advertised" were. A
healthy control channel says nothing about whether it carries the data you need.
