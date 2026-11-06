---
title: "Hunt the single point of failure"
---

## The situation

Last lesson put two app servers behind the load balancer. Look at the rest of
the stack and it seems everything comes in pairs:

```
              www
         lb1       lb2        two load balancers
        web1       web2       two app servers
         pg1  ───▶  pg2       a primary and its replica
     etcd1   etcd2   etcd3    three cluster members
```

Two of something is not the same as surviving the loss of one. A twin only
helps if something moves the work to it when the first one dies, and the
diagram does not show you that part.

## Your objectives

Write `/ha/answers/spof.txt`: one node name per line, listing every node
whose loss **on its own** stops the shop. "Stops" means either:

- `www` stops answering `GET /`, or
- `POST /orders` through `www` fails.

List exactly those nodes: no more, no fewer.

The setup is not the same every time you start the lesson. Which load balancer
holds `www`, and what HAProxy does with web2, vary between starts. Answer for
the stack in front of you.

## What you're being graded on

The grader kills each of the nine nodes in turn with `docker kill`, waits 8
seconds, sends 20 requests and one order through `www`, and starts the node
again. A node is a single point of failure if anything failed. Your list must
match that set exactly. Every mistake is reported, with what happened when the
node died.

## Try it yourself

That is the whole method. Do it to every box:

```
node kill lb1
curl -s --max-time 2 http://www/ ; curl -s --max-time 5 -X POST http://www/orders
node start lb1
```

Give each node a few seconds after the kill, so HAProxy's health checks have
time to react, and again after the start.

<details>
<summary>Hint 1 — the address is a thing too</summary>

`www` is 172.29.22.100. It is not a container: it is an address that
keepalived adds to one load balancer's interface. A load balancer without a
keepalived config never takes it. Look in `/ha/lb1/` and `/ha/lb2/`, and at
`ip -br addr` on each (`docker exec devopslings-ha-lb1 ip -br addr`).

</details>

<details>
<summary>Hint 2 — read the server lines to the end</summary>

A `server` line can end in `backup` (only used when every other server is
down) or `disabled` (never used). One of those makes web2 a spare that takes
over. The other makes web1 the only server there is.

</details>

<details>
<summary>Hint 3 — a replica is not a failover</summary>

pg2 has every row pg1 has. The app is still configured with `host=pg1`
(`/ha/app.env`), and pg2 is read-only. Nothing in this stack promotes it or
points the app at it.

</details>

<details>
<summary>Solution</summary>

`pg1` is always on the list. The rest depends on the start:

- the one load balancer that has a `keepalived.conf` holds `www`, and nothing
  else will take it; the other load balancer runs HAProxy for nobody.
- `web1` is on the list when web2's server line says `disabled`. With
  `backup`, or with no keyword, web2 takes over.
- `pg2`, and each etcd member, are never on it: nothing the shop does depends
  on them.

For example:

```
lb2
pg1
```

### Why you break things instead of reading

Every mistake in this lesson is easy to make from the diagram and impossible
to make with `node kill`. Two load balancers look redundant until you notice
that only one of them can ever own the address. A second app server looks like
a spare, or like a peer, depending on a word at the end of a line. A replica
looks like a backup database until you ask who would switch the app to it.

Redundancy is a property of the failover path, not of the box count. The
question for each node is not "is there another one?" but "when this one
dies, what moves the work, and has anyone seen it happen?"

### What the next lessons fix

The address (keepalived on both load balancers), the health check that lets
HAProxy move traffic, the session state that stops two app servers from being
interchangeable, and the database that can only be written in one place.

</details>
