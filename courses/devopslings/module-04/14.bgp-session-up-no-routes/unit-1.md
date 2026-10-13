---
title: "the BGP session is up, and the internet still cannot find us"
---

## The situation

This box is our edge router, AS 65010. The transit circuit to the provider,
AS 64500, went live this morning, and the BGP session came straight up:

```
$ vtysh -c 'show bgp ipv4 summary'
Neighbor        V    AS   MsgRcvd MsgSent ... Up/Down  State/PfxRcd   PfxSnt Desc
10.83.0.2       4 64500      312     314 ... 05:11:42  (Policy)       (Policy) transit-isp
```

The provider's NOC says they're receiving nothing from us. Nobody outside can
reach our public block, `198.51.100.0/24`. From a user out on the internet,
behind the provider:

```
$ ip netns exec isp curl -s -m 5 --interface 192.0.2.10 http://198.51.100.10:8080/
$ echo $?
28
```

The route we're meant to announce is right there in our own BGP table:

```
$ vtysh -c 'show bgp ipv4 unicast'
     Network          Next Hop   Metric LocPrf Weight Path
 *>  10.82.0.0/24     0.0.0.0         0         32768 ?
 *>  10.83.0.0/30     0.0.0.0         0         32768 ?
 *>  172.31.0.0/24    0.0.0.0         0         32768 ?
 *>  198.51.100.0/24  0.0.0.0         0         32768 ?
```

## Your objective

Make the user at `192.0.2.10` reach `198.51.100.10:8080` through BGP in both
directions. The provider learns `198.51.100.0/24` from us, and we learn
`192.0.2.0/24` from them. Don't use static routes, and don't change the
provider's router. We announce our public block and nothing else, and the fix
has to survive a restart of `frr.service`.

## What you're being graded on

The session is `Established`. This box advertises exactly `198.51.100.0/24` to
`10.83.0.2`, and `192.0.2.0/24` is in the kernel table `proto bgp`. The user
fetches the page. `/etc/frr/frr.conf` carries an inbound and an outbound policy
for the provider and doesn't turn the safety default off.

<details>
<summary>Hint 1: read the last two columns</summary>

`State/PfxRcd` and `PfxSnt` normally hold numbers: how many prefixes this box
accepted from the neighbour and how many it sent. Here they hold a word, the
same word in both. Ask the neighbour detail what it means:

```
$ vtysh -c 'show bgp ipv4 neighbors 10.83.0.2' | grep -i policy
  Inbound updates discarded due to missing policy
  Outbound updates discarded due to missing policy
```

</details>

<details>
<summary>Hint 2: RFC 8212</summary>

An eBGP session with no filter accepts whatever the neighbour sends and
announces everything this router knows. That default caused some of the
internet's worst outages: a small network accidentally re-announces a large
one's routes, and the large network's traffic goes the wrong way.

RFC 8212 flipped the default. An eBGP session with **no policy** sends nothing
and accepts nothing, so you have to say what you mean. FRR follows it, and so
does most modern router software.

So "no policy" here doesn't mean "no restrictions". It means "no traffic".

</details>

<details>
<summary>Hint 3: what "our block and nothing else" rules out</summary>

`redistribute connected` puts every connected network into BGP. That includes
the internal `10.82.0.0/24`, the link to the provider, and the lab network. Turn
off the safety default and all of those go to the provider. Their filter drops
the extras today, but you can't rely on every provider's filter, every day.

A policy that names `198.51.100.0/24` is the answer: a prefix-list, a route-map
that matches it, and that route-map applied to the neighbour `out`.

</details>

## Why the session is fine and the circuit is useless

BGP separates the **session**, two routers agreeing to talk, from the **routes**
they exchange. The session is a TCP connection on port 179 with keepalives, and
it's healthy. `Established` and a climbing message count say exactly that, and
nothing more.

The routes have their own gate. RFC 8212 closes it on every external session
until a policy opens it, in each direction separately. That's why nothing goes
out, and also why the provider's `192.0.2.0/24` never comes in. Fixing only the
outbound half gets our block to the provider, and the user's packets reach us.
Our replies then have no route back.

## The fix

<details>
<summary>Solution</summary>

Say what goes out and what comes in, and announce the block explicitly rather
than every connected network:

```
$ vtysh
edge# configure terminal
edge(config)# ip prefix-list OUR-PREFIXES seq 5 permit 198.51.100.0/24
edge(config)# route-map TRANSIT-OUT permit 10
edge(config-route-map)#  match ip address prefix-list OUR-PREFIXES
edge(config-route-map)# exit
edge(config)# route-map TRANSIT-IN permit 10
edge(config-route-map)# exit
edge(config)# router bgp 65010
edge(config-router)# address-family ipv4 unicast
edge(config-router-af)# no redistribute connected
edge(config-router-af)# network 198.51.100.0/24
edge(config-router-af)# neighbor 10.83.0.2 route-map TRANSIT-OUT out
edge(config-router-af)# neighbor 10.83.0.2 route-map TRANSIT-IN in
edge(config-router-af)# end
edge# write memory
edge# show bgp ipv4 summary
10.83.0.2       4 64500  ...  00:00:41            1        1 transit-isp
```

One prefix in, one prefix out. `TRANSIT-IN` here accepts whatever the provider
sends. A real edge would also drop bogons and our own block coming back.

</details>

## What not to do

**`no bgp ebgp-requires-policy`.** It works instantly, and it announces
everything in the BGP table to the provider. With `redistribute connected`
that's every internal network on the box. It only stays harmless while the
provider's filter keeps catching it. This is the textbook route leak, and the
default exists to prevent it.

**A `permit` route-map with no `match`, applied both ways.** It satisfies the
rule and changes nothing about what leaves, so the leak is the same.

**Add a static route back to `192.0.2.0/24`.** That fixes one user's prefix out
of the whole internet. The provider is offering us real routes, and we should
accept them.

**Fix it in `vtysh` and stop.** It works until the next restart of
`frr.service`, which loads `/etc/frr/frr.conf`, and the circuit goes quiet
again.

## Carrying this forward

With BGP, check the session and the routes separately. `Established` covers
only the session. Then read `PfxRcd` and `PfxSnt`, and use
`show bgp ipv4 neighbors <peer> advertised-routes` / `received-routes` to see
exactly what crossed. A number of zero means a filter matched nothing, and the
word `(Policy)` means there's no filter at all.

On any external session, write the outbound filter first and make it name what
you own. Large-scale BGP outages are rarely caused by a session going down.
They're caused by a session that stayed up and carried the wrong thing.
