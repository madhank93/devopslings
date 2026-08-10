---
title: "build a container's network by hand, then name what Docker was doing"
---

## The situation

Two network namespaces exist. Each has a loopback interface and nothing else:

```
$ ip netns exec app1 ip -br addr show
lo   UNKNOWN   127.0.0.1/8 ::1/128
```

That is not a broken container. That is what every container is, before
something wires it up. `docker run` creates exactly this and then does four more
things, quickly, in a way that leaves nothing to read afterwards.

This lesson is those four things, by hand.

## Your objective

Wire `app1` and `app2` so that all three work:

1. `app1` can ping `app2`
2. `app1` can fetch `http://172.31.0.10:8080/` from this box
3. `app1` can ping `172.31.0.11`, the peer box on the lab network

Use `10.77.0.0/24`, with the bridge holding `10.77.0.1`. The namespaces must be
joined by a bridge named `br0`, one veth pair each.

The third one needs more than addresses. The peer has never heard of
`10.77.0.0/24` and will not route a reply to it.

## What you're being graded on

`br0` exists with two interfaces enslaved, both namespaces addressed in
`10.77.0.0/24`, app1 reaching app2, app1 fetching the page, and app1 pinging the
peer.

<details>
<summary>Hint 1 — the four pieces</summary>

- A **bridge** — a software switch living in the box's network namespace.
- A **veth pair** — two interfaces joined end to end. Whatever goes in one comes
  out the other. One end goes inside the namespace; the other becomes a port on
  the bridge.
- A **route** — the namespace needs to know where to send anything that is not
  on its own subnet.
- **Translation** — because the rest of the world has no route back to
  `10.77.0.0/24`.

```
ip link add br0 type bridge
ip link add veth-app1 type veth peer name eth0-in
ip link set eth0-in netns app1
ip link set veth-app1 master br0
```

</details>

<details>
<summary>Hint 2 — the interface you forgot to bring up</summary>

A veth pair has two ends and both start down. Bringing up the end inside the
namespace and forgetting the end on the bridge is the single most common way
this fails, and it fails silently: the addresses are right, the routes are
right, and nothing moves.

```
$ ip link show master br0
$ ip netns exec app1 ip -br link show
```

Anything reading `DOWN` or `LOWERLAYERDOWN` is your answer.

</details>

<details>
<summary>Hint 3 — check 2 versus check 3</summary>

Getting to the box needs the box to be willing to forward:

```
$ cat /proc/sys/net/ipv4/ip_forward
0
```

Getting to the **peer** needs one more thing. Watch what the peer sees:

```
$ ip netns exec app1 ping 172.31.0.11 &
$ tcpdump -i eth0 -nn icmp
IP 10.77.0.2 > 172.31.0.11: ICMP echo request
```

The request arrives. The peer replies to `10.77.0.2`, has no idea where that is,
and sends the reply to its own default gateway, which is not you.

</details>

## The mapping

Every piece has a Docker equivalent, and this is the reason to build it once by
hand:

| You built | Docker calls it |
|---|---|
| `br0` | `docker0`, or `br-<id>` for a user-defined network |
| `veth-app1` on the bridge | the `veth<hash>` interfaces cluttering `ip link` on any Docker host |
| `eth0-in` inside the namespace | the container's `eth0` |
| `10.77.0.1` on the bridge | the container's default gateway |
| `net.ipv4.ip_forward=1` | what the Docker daemon sets on startup, on your host, without asking |
| the masquerade rule | why containers reach the internet and nothing reaches them back |

`docker network inspect bridge` prints the subnet and the gateway. Those are the
two numbers you just chose yourself.

## Solving it

<details>
<summary>Solution</summary>

```
# 1. the switch
ip link add br0 type bridge
ip addr add 10.77.0.1/24 dev br0
ip link set br0 up

# 2. a cable per namespace — both ends up
i=2
for ns in app1 app2; do
  ip link add "veth-$ns" type veth peer name eth0-in
  ip link set eth0-in netns "$ns"
  ip link set "veth-$ns" master br0
  ip link set "veth-$ns" up

  ip netns exec "$ns" ip addr add "10.77.0.$i/24" dev eth0-in
  ip netns exec "$ns" ip link set eth0-in up
  ip netns exec "$ns" ip link set lo up
  ip netns exec "$ns" ip route add default via 10.77.0.1
  i=$((i + 1))
done

# 3. the box becomes a router
sysctl -w net.ipv4.ip_forward=1

# 4. and lies about who the traffic came from
nft add table ip lab-nat
nft 'add chain ip lab-nat post { type nat hook postrouting priority 100 ; }'
nft add rule ip lab-nat post ip saddr 10.77.0.0/24 oifname "eth0" masquerade
```

Check 1 passes after step 2 — two namespaces on the same bridge and the same
subnet need no router at all, because they are on one link. Check 2 passes after
step 3. Check 3 needs step 4, because forwarding gets the packet out and nothing
gets the reply back.

</details>

## What this explains later

**Why containers can reach out and not be reached.** Nothing outside knows the
container subnet exists. `docker run -p` is a second NAT rule in the other
direction, and the next lesson is what happens when it only half works.

**Why `ip link` on a Docker host is full of junk.** Each `veth<hash>` is the
bridge end of a pair whose other end is inside a container. Delete one and that
container loses its network.

**Why two containers on the same user-defined network find each other and two on
different networks do not.** Different bridge, different link. Routing between
them would have to be arranged, and by default it is not.

**Why `--network host` is a different thing entirely.** It does not wire a
namespace up quickly. It skips the namespace: the process runs in the host's
network namespace, sees the host's interfaces, and binds the host's ports.

## Carrying this forward

A container's network is four commands and no magic. When container networking
misbehaves, the question is always which of the four is missing — the link, the
address, the route, or the translation — and each has a command that answers it
directly: `ip link show master`, `ip -br addr`, `ip route get`, `nft list ruleset`.
