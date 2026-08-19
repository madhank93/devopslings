---
title: "The API can't reach Redis, and both containers are healthy"
---

## The situation

Two services, one compose file. `docker compose ps` shows both up. Redis is
published on the host and you can reach it from your laptop. The API cannot.

```
$ curl -s localhost:18081/health
{"error":"Error 111 connecting to localhost:6379. Connection refused.",
 "redis":"redis://localhost:6379","status":"degraded"}

$ redis-cli -p 16379 ping
PONG
```

Redis is definitely running — you just talked to it. The API, sitting right
next to it, gets connection refused.

The person who wrote this added `ports:` to the Redis service specifically to
fix this, and it did not help. Understanding why is the lesson.

## Your objectives

1. Explain what `localhost` means inside the `api` container.
2. Make the API reach Redis over the compose network.
3. Confirm writes actually land — `/hits` should increment on each call.

## What you're being graded on

That `/health` returns ok, that the address the API uses stays on the container
network, and that `/hits` really increments.

There is a fix that makes `/health` go green and still fails this check. If you
find yourself typing `host.docker.internal`, read hint 3 first.

<details>
<summary>Hint 1 — what is localhost, exactly</summary>

`localhost` is not a place. It is "this network namespace".

Each container gets its own network namespace, so each container has its own
`localhost` and its own loopback interface. Inside `api`, `localhost:6379`
means "port 6379 in the api container" — where nothing is listening.

Prove it:

```
docker compose -p devopslings-compose-networking exec api bash
apt-get update && apt-get install -y iproute2 dnsutils   # or just try the next bit
python3 -c "import socket; socket.create_connection(('localhost',6379),2)"
```

</details>

<details>
<summary>Hint 2 — how containers find each other</summary>

Compose puts every service on a shared network and runs a DNS resolver on it.
Each service is resolvable by its **service name** — the key in the compose
file, not the container name and not the image name.

```
docker compose -p devopslings-compose-networking exec api python3 -c \
  "import socket; print(socket.gethostbyname('cache'))"
```

Note the port you'd use with it. `ports:` maps a container port to a *host*
port; it has nothing to do with container-to-container traffic. The port to use
between containers is the one the process is actually listening on.

</details>

<details>
<summary>Hint 3 — the fix that works and is still wrong</summary>

Redis is published on the host as `16379`, and containers can often reach the
host via `host.docker.internal`. So this makes `/health` go green:

```yaml
REDIS_URL: "redis://host.docker.internal:16379"
```

Trace the path that traffic takes: out of the api container, onto the host's
network stack, back in through a published port, into the cache container. Two
extra hops to reach a container on the same bridge.

`host.docker.internal` is a Docker Desktop convenience that does not exist on a
stock Linux daemon, and published ports usually are not published in the
environment you deploy to. The check rejects it for that reason.

</details>

<details>
<summary>Solution</summary>

Point the API at the service name and the port Redis actually listens on:

```yaml
services:
  api:
    build: .
    ports:
      - "18081:8080"
    environment:
      REDIS_URL: "redis://cache:6379"
    depends_on:
      - cache

  cache:
    image: redis:7-alpine
```

```
$ docker compose -p devopslings-compose-networking up -d --build
$ curl -s localhost:18081/health
{"redis":"redis://cache:6379","status":"ok"}
$ curl -s localhost:18081/hits
{"hits":1}
$ curl -s localhost:18081/hits
{"hits":2}
```

Note that `ports:` came off the `cache` service entirely. It was never doing
anything for the API, and removing it stops Redis being reachable from
anywhere on your machine — which is what you want for a datastore.

### The two networks people conflate

**Published ports (`ports:`)** are host → container. `"16379:6379"` tells the
daemon to listen on the *host's* 16379 and forward to 6379 in the container.
Useful for reaching a service from your browser or `redis-cli`. Irrelevant to
container-to-container traffic, and a small security cost since it exposes the
service on your machine.

**The compose network** is container → container. Every service joins it, DNS
resolves service names to container IPs, and all ports are reachable without
publishing anything. `expose:` documents which ports a service offers; it does
not open anything, because nothing needed opening.

So the original compose file had two independent mistakes that looked like one:
`localhost` was the wrong host, and `ports:` was the wrong tool for the job it
was added to do.

### About `depends_on`

`depends_on: [cache]` controls **start order**, not readiness. Compose starts
`cache` first and then starts `api` immediately — it does not wait for Redis to
accept connections. On a slow machine the API can still get connection refused
on its first attempt.

If the app cannot retry, make the dependency conditional on health:

```yaml
  cache:
    image: redis:7-alpine
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 2s
      retries: 10

  api:
    depends_on:
      cache:
        condition: service_healthy
```

Retrying in the application is better still — dependencies restart in
production, long after startup ordering has stopped being relevant.

</details>
