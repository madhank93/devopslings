---
title: "healthy, and dropping every real request"
---

## The situation

`quote-api` was moved to a distroless base image last sprint. Since then the
load balancer marks it healthy and every real request fails:

```
$ curl http://127.0.0.1:18431/healthz
ok
$ curl http://127.0.0.1:18430/quote
curl: (56) Recv failure: Connection reset by peer
$ docker logs quote-api
health listener ready
api listener ready
```

Both listeners say they are ready. The usual next step does not exist:

```
$ docker exec -it quote-api sh
OCI runtime exec failed: exec: "sh": executable file not found in $PATH
```

A distroless image holds the application and its runtime and nothing else: no
shell, no `ps`, no `ss`, no package manager. That is the point of it — less to
patch, less for an attacker to use. The proposal on the table is to rebuild it
on a base with a shell "just to debug". That would be debugging a different
image.

## Bring the tools to the container

A container is a process in a set of Linux namespaces. Another container can
be started *inside some of those same namespaces*, carrying its own tools:

```
docker run --rm -it --network=container:quote-api busybox:1.37
```

- `--network=container:quote-api` puts the tools container in the target's
  network namespace: same interfaces, same addresses, same listening sockets.
  `netstat -ltn` in there lists the target's sockets.
- `--pid=container:quote-api` shares its process namespace: the target's
  processes appear in `ps`, and `/proc/<pid>/` exposes each one's command line,
  environment, open files and, through `/proc/<pid>/root`, its filesystem.
- Reading another user's `/proc/<pid>/root` or `/proc/<pid>/environ` is a
  ptrace-level access. The target runs as a non-root user; root in the tools
  container still needs `--cap-add SYS_PTRACE` for those.

`docker debug` and `kubectl debug --target=` do the same thing with a nicer
interface. The image under investigation is never modified.

The config is in the `quote-api-config` volume, mounted read-only into the
target. It can be edited from any container that mounts the volume.

## Your objectives

1. Write where the API socket is actually listening, as the socket table in
   the target's network namespace shows it, to
   `scratch/debug-a-distroless-container/answers/distroless.txt`:

   ```
   listening=<address>:<port>
   ```

2. Fix it in the config so that `curl http://127.0.0.1:18430/quote` returns a
   quote.

## What you're being graded on

The check reads your answer, then confirms that `quote-api` is running the
exact image it was deployed with (same image ID), that health checks still
pass, and that a real request on 127.0.0.1:18430 gets a quote.

<details>
<summary>Hint 1 — compare the two listeners</summary>

From the tools container, `netstat -ltn` shows two listening sockets. Look at
the *Local Address* column: one is listening on every address, the other on
one.

</details>

<details>
<summary>Hint 2 — where published traffic arrives</summary>

`-p 127.0.0.1:18430:8080` forwards connections to port 8080 on the container's
`eth0` address, not to its loopback. A socket bound to `127.0.0.1` inside the
container is reachable only from inside that network namespace — which is why
it works from the tools container and not from your host.

</details>

<details>
<summary>Solution</summary>

```
$ docker run --rm --network=container:quote-api busybox:1.37 netstat -ltn
Proto Recv-Q Send-Q Local Address           Foreign Address         State
tcp        0      0 127.0.0.1:8080          0.0.0.0:*               LISTEN
tcp        0      0 0.0.0.0:8081            0.0.0.0:*               LISTEN
```

```
listening=127.0.0.1:8080
```

The config, read through the target's own filesystem:

```
$ docker run --rm --cap-add SYS_PTRACE --pid=container:quote-api busybox:1.37 \
    cat /proc/1/root/etc/quote-api/app.ini
[health]
listen = 0.0.0.0:8081

[api]
listen = localhost:8080
```

`localhost` is a reasonable thing to write on a VM, where the load balancer
talks to a local reverse proxy. In a container, it means "only from inside
this network namespace". Health checks hit the other listener, so they pass.

Fix the config through the volume and restart the same container:

```
docker run --rm -v quote-api-config:/c busybox:1.37 \
  sed -i 's/^listen = localhost:8080$/listen = 0.0.0.0:8080/' /c/app.ini
docker restart quote-api
```

### Why the health check lied

The health endpoint is served by a different listener from the traffic, so it
proved that the process was alive and nothing about whether it could serve.
A health check that goes through the same listener and path as real requests
would have failed this deploy before it took traffic — module 09's
`healthcheck-semantics` makes the same point from the other side.

</details>
