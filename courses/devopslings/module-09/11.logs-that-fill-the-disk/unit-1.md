---
title: "nothing is broken and the host runs out of disk every Thursday"
---

## The situation

`quote-api` has not been deployed in six weeks. It is healthy, it is fast, and
roughly every Thursday the host it runs on runs out of disk and somebody clears
space by hand.

The service writes a line per request at debug level. That is a decision
somebody made once and it is not the bug. The bug is that nothing ever removes
those lines:

```
$ docker compose -p devopslings-logs up -d --build
$ docker compose -p devopslings-logs wait quote-api
$ docker logs $(docker compose -p devopslings-logs ps -aq quote-api) | wc -c
40688914
```

Forty megabytes for one replay of a day's traffic. Nothing rotates it, nothing
expires it, and the file is not in `/var/log` where you would look for it.

The fix everyone tries first is to delete the file. It does not work, and the
reason it does not work is worth knowing before you try it.

## Your objectives

1. Bound what one container can leave on disk, so a week of this cannot fill
   the host.
2. Keep the logs readable: `docker logs` still has to work, and the most recent
   output has to survive.

The service keeps logging exactly as much as it does now. Making it quieter is a
real option in real life, with real consequences for the next incident, and it
is not the change this exercise is about.

## What you're being graded on

The grader runs your image once with no log options to measure what the service
emits, so a quieter service fails rather than passes. Then it runs your compose
service and requires that what stays readable afterwards is a small fraction of
that, that `docker logs` still works, and that the last line the service wrote
is still in it.

<details>
<summary>Hint 1 — find the file</summary>

```
docker inspect -f '{{.LogPath}}' $(docker compose -p devopslings-logs ps -aq quote-api)
```

That path is on the machine running the daemon. If Docker is in a VM — Docker
Desktop, OrbStack, Colima — it is not on your Mac's filesystem and `ls` will not
find it. Look through a container instead:

```
cid=$(docker compose -p devopslings-logs ps -aq quote-api)
docker run --rm -v /:/host:ro alpine:3.20 \
  ls -la "/host$(dirname "$(docker inspect -f '{{.LogPath}}' "$cid")")"
```

</details>

<details>
<summary>Hint 2 — why deleting it does nothing</summary>

The daemon holds that file open for as long as the container exists. Unlinking a
file that a process still has open removes the *name*, not the data: the inode
stays, the space stays allocated, and the writer keeps writing into a file with
no path. `df` still says the disk is full and `du` can no longer find what is
using it — the exact situation `disk-full-triage` in module 01 was about.

`truncate -s 0` on the file does free the space, and buys you until the log grows
back. Neither is a fix; both are a Thursday ritual.

</details>

<details>
<summary>Hint 3 — the driver is the thing to configure</summary>

Every container's stdout goes to a **logging driver**, and the default —
`json-file` — writes one file and never rotates it unless you say so.

```yaml
services:
  quote-api:
    logging:
      driver: json-file
      options:
        max-size: "..."
        max-file: "..."
```

`max-size` caps one file; `max-file` caps how many are kept. `max-file` on its
own does nothing, because nothing ever reaches the point of rotating.

</details>

<details>
<summary>Solution</summary>

```yaml
services:
  quote-api:
    build: .
    logging:
      driver: json-file
      options:
        max-size: "1m"
        max-file: "3"
```

```
$ docker logs $(docker compose -p devopslings-logs ps -aq quote-api) | wc -c
1581631

$ docker logs $(docker compose -p devopslings-logs ps -aq quote-api) | tail -1
replayed 200000 requests
```

And on the daemon's filesystem, the shape of what that means:

```
-rw-r----- 1 root root  261323 …-json.log
-rw-r----- 1 root root 1000008 …-json.log.1
-rw-r----- 1 root root 1000027 …-json.log.2
```

The ceiling is `max-size × max-file` — about 3 MB here — regardless of how long
the service runs or how much it says. The oldest output is what gets dropped,
which is the right way round: during an incident you want the last few minutes,
not the first.

### The part worth remembering

**A container's stdout is a file on the daemon's host, and by default it is
unbounded.** Not `/var/log`, not managed by logrotate, not counted by anything
you would normally watch: `/var/lib/docker/containers/<id>/<id>-json.log`. It
grows for the life of the container and is deleted when the container is
removed, which is why "restart it and the disk frees up" is folk knowledge that
happens to be true and teaches the wrong lesson.

**Set the default on the daemon, not on each service.** A per-service `logging:`
block fixes one service written by one person who knew about this. The host-wide
version is in `/etc/docker/daemon.json`, and it is the one that survives the next
compose file somebody adds:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "3" }
}
```

That is a daemon restart, and it applies to containers created afterwards —
existing ones keep the settings they were created with.

The drivers worth knowing:

- **`json-file`** — the default. Rotates only when told to. `docker logs` reads
  it, including across rotated files.
- **`local`** — same idea, compressed, and it *does* rotate by default: 20 MB a
  file and five of them, so roughly 100 MB rather than unbounded. Better than
  `json-file`'s default and still worth setting explicitly if you want a tighter
  bound. `docker logs` works.
- **shipping drivers** (`syslog`, `journald`, `fluentd`, `awslogs`, …) — send the
  lines somewhere else. The bound then lives in that system, and a network
  problem becomes a logging problem: some of these block the container's writes
  when the destination is unreachable.
- **`none`** — bounds the disk by discarding everything. `docker logs` returns
  nothing, and the next incident is debugged without them.

`none` is the answer this lesson refuses on purpose. It makes the symptom go
away perfectly, which is exactly what makes it tempting, and it trades a disk
problem you can see for an observability problem you find out about later.

</details>
