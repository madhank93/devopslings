---
title: "docker stop takes exactly ten seconds, every time"
---

## The situation

Deploys are slow. Not catastrophically — just ten seconds per container, every
time, on every rollout. With forty containers that is a seven-minute deploy
spent doing nothing.

The application has a shutdown handler. It is supposed to log
`SIGTERM received, draining connections...`, finish what it is doing, and
exit. Nobody has ever seen that line in production.

```
$ docker build -t devopslings-pid1 .
$ docker run -d --name pid1-demo devopslings-pid1
$ time docker stop pid1-demo
pid1-demo
docker stop pid1-demo  0.02s user 0.01s system 0% cpu 10.421 total

$ docker logs pid1-demo
worker started
```

Ten seconds. Not 9.6, not 11 — ten. And the handler never ran.

## Your objectives

1. Work out why the handler never runs.
2. Fix it so the container stops promptly and shuts down cleanly.

Your scratch directory has `Dockerfile` and `app.py`. You should not need to
change `app.py` — read it first and confirm the handler is correct, because
knowing the application is fine is what points you at the container.

## What you're being graded on

That `docker stop` completes in under five seconds, that the container logged
`graceful shutdown complete`, and that the app is still the process doing the
work.

<details>
<summary>Hint 1 — the number ten is a clue</summary>

Ten seconds is Docker's default stop grace period. The sequence is:

1. `docker stop` sends `SIGTERM` to PID 1 in the container
2. it waits up to ten seconds
3. if the container is still alive, it sends `SIGKILL`

You are getting the full grace period and then a kill. That means PID 1 is
receiving `SIGTERM` and doing nothing about it — or PID 1 is not who you think
it is.

</details>

<details>
<summary>Hint 2 — find out what PID 1 actually is</summary>

```
docker run -d --name pid1-demo devopslings-pid1
docker exec pid1-demo ps -ef
```

You expected one process. Count how many there are, and note which one has
PID 1.

</details>

<details>
<summary>Hint 3 — shell form versus exec form</summary>

```dockerfile
CMD python3 app.py          # shell form
CMD ["python3", "app.py"]   # exec form
```

The first is silently rewritten to `/bin/sh -c "python3 app.py"`. Look up what
`sh` does with a `SIGTERM` when it is waiting on a child.

</details>

<details>
<summary>Solution</summary>

Look at what is actually running:

```
$ docker exec pid1-demo ps -ef
UID    PID  PPID  CMD
root     1     0  /bin/sh -c python3 app.py
root     7     1  python3 app.py
```

There are two processes. `sh` is PID 1; the application is PID 7.

`docker stop` signals PID 1, so `sh` gets the `SIGTERM`. A non-interactive
`sh` waiting on a child does not forward signals to it and does not exit while
the child runs. So the signal arrives, nothing happens, ten seconds pass, and
`SIGKILL` takes down the whole container — including the app, which never saw
a thing.

The cause is the `CMD` line:

```dockerfile
CMD python3 app.py
```

Shell form. Docker rewrites it to `/bin/sh -c "python3 app.py"`, which is where
the extra process comes from. Use exec form instead:

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY app.py .
CMD ["python3", "app.py"]
```

```
$ docker exec pid1-demo ps -ef
UID    PID  PPID  CMD
root     1     0  python3 app.py

$ time docker stop pid1-demo
docker stop pid1-demo  0.02s user 0.01s system 4% cpu 0.312 total

$ docker logs pid1-demo
worker started
SIGTERM received, draining connections...
graceful shutdown complete
```

### The part worth remembering

Being PID 1 is not just about who gets the signal. PID 1 has different kernel
semantics from every other process: default signal dispositions do not apply,
so a process that has not explicitly installed a handler will **ignore**
`SIGTERM` rather than die from it. A shell script as PID 1 will usually sit
there. So will anything else that assumes the default behaviour.

PID 1 is also responsible for reaping orphaned children. A process that never
calls `wait()` leaves zombies accumulating in the container's process table.

Three ways this gets handled in practice:

- **Exec form**, so the app really is PID 1 — correct when the app handles
  signals properly, which is the case here.
- **`ENTRYPOINT ["/usr/bin/tini", "--"]`** or `docker run --init`, which puts a
  tiny init process at PID 1 to forward signals and reap zombies. Right when
  you genuinely need a wrapper script, or the app spawns children.
- **`exec` in the wrapper script** — `exec python3 app.py` replaces the shell
  rather than forking, so the app inherits PID 1.

Shell form is not always wrong: it is how you get variable expansion in a `CMD`.
But if you use it, know that you have put a shell at PID 1 and decide what that
shell should do about signals.

</details>
