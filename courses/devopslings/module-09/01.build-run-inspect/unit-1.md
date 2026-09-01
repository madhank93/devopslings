---
title: "the container ran, the report is gone"
---

## The situation

`report.py` totals the day's orders and writes a report. It runs fine on your
laptop, and it is about to run on a box that has no Python. So it goes in a
container.

That part is three lines of Dockerfile. The part that surprises everyone the
first time is what happens next:

```
$ docker run --name report-run devopslings-report
wrote /out/report.txt

$ ls
Dockerfile  orders.csv  report.py
```

The container says it wrote the file. The host does not have it. Nothing
failed — the exit code is 0 — and the report is nowhere you can see.

## Your objectives

1. Write a `Dockerfile` that runs `report.py`, and build it as
   `devopslings-report`.
2. Run it in a container named `report-run`, without `--rm`, and let it exit.
3. Get the report that run produced onto the host at `recovered/report.txt`.
   The container has already exited; do not just run it again.
4. Then make a *second* run put the report on the host by itself, at
   `out/report.txt` — no copying afterwards.

`report.py` reads `/app/orders.csv` and writes `/out/report.txt`. You should not
need to change it, or `orders.csv`.

## What you're being graded on

That `devopslings-report` exists and a container from it produces the right
report; that `report-run` is still there and exited 0; and that both
`recovered/report.txt` and `out/report.txt` match what the image actually
writes. The grader runs your image itself, so a report you typed by hand will
not match one.

<details>
<summary>Hint 1 — the Dockerfile</summary>

Four instructions is enough: a base image with Python in it, a working
directory, the two files copied in, and the command to run.

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY ...
CMD [...]
```

Prefer the JSON array form of `CMD` — lesson 02 is about what the other form
does to you.

</details>

<details>
<summary>Hint 2 — the file did not go nowhere</summary>

`report-run` has exited. It has not been deleted.

```
docker ps -a           # it is still listed
docker diff report-run # every path its run changed
```

A stopped container still owns the filesystem it wrote to. There is a `docker`
subcommand for moving files between that filesystem and yours, and it works on
a container that is not running.

</details>

<details>
<summary>Hint 3 — the next run should not need rescuing</summary>

Copying the file out afterwards is a rescue. The routine version is to give the
container a directory that is already on the host:

```
docker run --rm -v "$(pwd)/out:/out" devopslings-report
```

Create `out/` first. Then look at what that did to the container:

```
docker inspect -f '{{json .Mounts}}' <container>
```

</details>

<details>
<summary>Solution</summary>

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY orders.csv report.py ./
CMD ["python3", "report.py"]
```

```
$ docker build -t devopslings-report .
$ docker run --name report-run devopslings-report
wrote /out/report.txt
```

The report is in `report-run`'s own filesystem. `docker diff` shows it:

```
$ docker diff report-run | grep /out
A /out
A /out/report.txt
```

`A` for added. (The unfiltered output is noisier than you expect — a base image
does its own housekeeping on first run.) Copy it out — the container is exited, and that is fine:

```
$ mkdir -p recovered
$ docker cp report-run:/out/report.txt recovered/report.txt
$ cat recovered/report.txt
orders: 4
total: 1290
```

For the next run, mount a host directory at `/out` so the write lands on the
host as it happens:

```
$ mkdir -p out
$ docker run --rm -v "$(pwd)/out:/out" devopslings-report
wrote /out/report.txt
$ cat out/report.txt
orders: 4
total: 1290
```

### The part worth remembering

A container's filesystem is the image's layers, which are read-only and shared
by every container from that image, plus one thin writable layer that belongs
to that container alone. `report.py` wrote into the writable layer.

That layer is not deleted when the process exits. It is deleted when the
*container* is deleted — `docker rm`, or `--rm` on the run that created it. So
there are two different questions that beginners run together:

- **Is the container running?** `docker ps` versus `docker ps -a`.
- **Does the container still exist?** Only that decides whether its files are
  still recoverable.

`--rm` is convenient and it is also the flag that would have thrown last
night's report away for good. Reach for it once you know nothing inside the
container is worth keeping.

Three ways data leaves a container, in the order you will need them:

- **`docker cp`** — after the fact, from a container that still exists. A
  rescue, not a design.
- **A bind mount** (`-v /host/path:/container/path`) — a host directory grafted
  into the container. Exactly the right thing for build output and reports.
  What you write is on the host, with host ownership rules; on Linux a
  root-in-container process leaves you root-owned files.
- **A named volume** (`-v myvol:/var/lib/data`) — storage Docker manages, which
  outlives the container without being tied to a host path. What databases use.

The mental model this lesson is really installing: a container is a process
with its own view of the filesystem. Not a small machine that keeps your
things. Everything the container wrote is inside that view unless you
deliberately put a door in the wall.

</details>
