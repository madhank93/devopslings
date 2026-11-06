---
title: "Active-active: two nodes, one session store"
---

## The situation

web1 and web2 both serve `www`, round-robin. A customer adds four things to
their cart, and the cart answers differently every time:

```
{"node": "web1", "sid": "8f3c…", "items": ["socks"]}
{"node": "web2", "sid": "8f3c…", "items": ["hat"]}
{"node": "web1", "sid": "8f3c…", "items": ["socks", "scarf"]}
{"node": "web2", "sid": "8f3c…", "items": ["hat", "gloves"]}
```

Same session id, two carts. Each node keeps sessions in a dictionary in its
own memory (`SESSION_STORE=memory` in `/ha/app.env`). Two nodes means two
dictionaries.

## Your objectives

1. A session written through either node is visible from both.
2. Losing a node loses none of the sessions it served.

`/ha/app.env` is read on every request, so a change applies at once. The app
can also keep sessions in the `sessions` table in Postgres
(`SESSION_STORE=postgres`), which both nodes reach.

## What you're being graded on

- **One session, both nodes.** The grader starts a cart through `www`, adds
  one item on web1 directly and one on web2 directly, with the same `sid`
  cookie. Asked directly, each node must return all three.
- **Losing the node.** It fills a cart through `www`, kills whichever node
  served it, and reads the cart through `www` again. Nothing may be missing.

## Try it yourself

```
sid=$(curl -s -X POST 'http://www/cart?item=a' | jq -r .sid)
curl -s -H "Cookie: sid=$sid" http://web1:8080/cart
curl -s -H "Cookie: sid=$sid" http://web2:8080/cart
```

<details>
<summary>Hint 1 — the first thing everyone tries</summary>

Sticky sessions: `cookie SERVERID insert` in the backend, or `balance
source`. Now every request from one customer lands on the node that has
their cart, and the symptom disappears.

Then that node dies. HAProxy sends the customer to the other one, which has
never heard of the session. Stickiness has not made the session shared. It
has made sure exactly one node holds it.

</details>

<details>
<summary>Hint 2 — move the state, not the user</summary>

If any node is to answer any request, the session cannot live in a node. It
has to live somewhere both nodes read from. The stack already has one.

</details>

<details>
<summary>Solution</summary>

In `/ha/app.env`:

```
SESSION_STORE=postgres
```

### Why sticky sessions are not the answer

Stickiness is a routing fix for a state problem. It is fine as a
performance optimisation on top of shared state: a node that has a session
cached answers faster. As the only mechanism, it means every node failure,
deploy and scale-down logs out every user on that node. And it skews load:
whatever the hash or cookie pins together stays together, however unevenly.

### What you have bought

Either node can now die and nobody's cart changes. The price is a database
round trip per session read, and a new dependency: if pg1 is down, so are
sessions. You have not removed the single point of failure. You have moved
it to a place that you can make highly available once, for everything that
uses it. The next lessons are about that place.

</details>
