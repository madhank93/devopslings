---
title: "Replay: Facebook, October 2021"
---

## The situation

On 4 October 2021 a command meant to assess the capacity of Facebook's
backbone instead disconnected all of it. An audit tool should have stopped
the command, and a bug let it through. Facebook's DNS servers check that
they can reach the data centers, and they withdraw their own BGP routes
when they cannot. That check exists so that a broken site stops receiving
traffic. Here every site was cut off, so every DNS server withdrew, and
facebook.com disappeared from the internet.

The fix was a configuration change on the backbone, and the engineers who
could make it had no way to reach the routers. Both their primary and their
out-of-band network access were down, and the internal tools they would
normally use depended on the DNS that had withdrawn itself. Engineers had to go to the data
centers in person. Physical access there is designed to be hard, so getting
in took hours. The outage lasted about six hours.

The replay does the same at the scale of two load balancers. Operators
manage HAProxy through its runtime API at `www:9999`, which is bound to the
VIP so that every tool needs only one address. keepalived holds www only on
a node whose `/announce` check passes, meaning the node has a server left
to send traffic to. `/ha/oob/INCIDENT.txt` has the timeline. A drain went
wrong on both nodes, both gave up www as designed, and the rollback has
nowhere to go.

## Your objectives

1. In `/ha/answers/facebook-2021.txt`, mark which things the operators'
   rollback could not have worked without.
2. Build a way in that does not depend on any of them. Choose a Docker
   network that both load balancers join and that the shop's own traffic
   does not use. Make each node's runtime API reachable on it. Record the
   network and both addresses in `/ha/oob/console.env`.
3. Write `/ha/oob/rollback.sh`. It must enable web1 and web2 on both load
   balancers through that path.

`docker exec` into a load balancer works from ops. Use it to get www back
while you explore. It is the lab's equivalent of walking into the data
center, and the grader does not give it to your rollback.

## What you're being graded on

The reconstruction first. Then the grader checks that your network exists,
is neither front nor back, and has lb1 and lb2 attached. It repeats the
drain on both nodes through each node's local socket and confirms that www
is down. Then it starts a console from the ops image. The console has no
Docker socket and no `/ha`, and its only network is the one you named. The
grader asks each node's API, from the console, to identify itself, and then
runs your `rollback.sh` there. It passes if both nodes have both servers
enabled and www answers again.

## Try it yourself

```
cat /ha/oob/INCIDENT.txt
timeout 3 bash -c 'exec 3<>/dev/tcp/www/9999; echo "show info" >&3; cat <&3'
docker exec devopslings-ha-lb1 lbctl stat
docker exec devopslings-ha-lb1 sh -c 'echo "show servers state app" | socat stdio /run/haproxy.sock'
docker run --rm -it --network <your network> --entrypoint bash $(docker inspect -f '{{.Image}}' devopslings-ha-ops)
```

The last line starts the same kind of console the grader uses.

<details>
<summary>Hint 1 — follow the rollback's path</summary>

Write down every hop the rollback needs. ops sends it over the front
network to 172.29.22.100. Some node has to hold that address. On that node,
HAProxy has to be listening on 9999. Then ask what decides whether a node
holds the address. That last question is where the loop closes.

</details>

<details>
<summary>Hint 2 — a network of its own</summary>

```
docker network create --subnet 172.29.24.0/24 devopslings-ha-oob
docker network connect --ip 172.29.24.11 devopslings-ha-oob devopslings-ha-lb1
docker network connect --ip 172.29.24.12 devopslings-ha-oob devopslings-ha-lb2
```

Joining the network is half of it. HAProxy only listens where its config
tells it to, and the scenario's API listens on the VIP and nowhere else.

</details>

<details>
<summary>Hint 3 — one shared config, two addresses</summary>

`/ha/haproxy.cfg` is the same file on both nodes, and each node needs to
listen on its own management address. With `transparent`, a node can bind
an address it does not have. List both addresses, and each node receives
traffic only on the one it owns:

```
global
    stats socket ipv4@172.29.24.11:9999 level admin transparent
    stats socket ipv4@172.29.24.12:9999 level admin transparent
```

</details>

<details>
<summary>Solution</summary>

```
cat > /ha/answers/facebook-2021.txt <<'TXT'
front_network: yes
the_vip: yes
haproxy_on_the_vip_holder: yes
an_enabled_server: yes
pg1: no
etcd: no
TXT

docker network create --subnet 172.29.24.0/24 devopslings-ha-oob
docker network connect --ip 172.29.24.11 devopslings-ha-oob devopslings-ha-lb1
docker network connect --ip 172.29.24.12 devopslings-ha-oob devopslings-ha-lb2
sed -i '/^global$/a\
    stats socket ipv4@172.29.24.11:9999 level admin transparent\
    stats socket ipv4@172.29.24.12:9999 level admin transparent' /ha/haproxy.cfg

cat > /ha/oob/console.env <<'ENV'
NETWORK=devopslings-ha-oob
LB1=172.29.24.11:9999
LB2=172.29.24.12:9999
ENV
cat > /ha/oob/rollback.sh <<'SH'
#!/bin/bash
set -euo pipefail
for api in "$LB1" "$LB2"; do
  exec 3<>"/dev/tcp/${api%:*}/${api##*:}"
  echo "enable server app/web1; enable server app/web2" >&3
  cat <&3
  exec 3<&-
done
SH
```

### The way in has to survive what it is for

Each piece of the incident was reasonable on its own. Drains are routine.
A node that gives up an address it cannot serve is good design: Facebook's
DNS servers did exactly that, and the same check protects users on an
ordinary day. Publishing management on one well-known address keeps
tooling simple. Put together, the only path to the fix ran through the
thing the mistake had taken away, and part of what took it away was the
system protecting itself.

An out-of-band path is defined by what it does not share with production.
That means its own network, its own addresses, and no dependency on the
VIP, production DNS or production authentication. Each node is reached
directly, because each node was broken separately. The only way to know
the path works is to use it with production down, which is what the grader
does. A path that is never exercised tends to be found broken during the
incident it was built for.

Leaving the API unauthenticated on a network is a choice the lab can make
and production cannot. A real out-of-band network carries the most
privileged access in the company, so it gets its own credentials and its
own monitoring. It must not depend on the production directory service for
logins.

Source: Facebook Engineering, "More details about the October 4 outage",
5 October 2021.

</details>
