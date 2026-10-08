---
title: "the deploy never goes healthy, and the reason moves"
---

## The situation

```
$ ./deploy.sh
 ...
 Container devopslings-container-triage-quotes-1 Healthy
container devopslings-container-triage-api-1 is unhealthy
```

That is the ticket, and it is the same ticket every time you run this lesson.
The fault is not the same. It is drawn at random from five, each one a
mechanism from this module, and every one of them looks exactly like this from
`deploy.sh`.

The stack is two services built from one image. `api` joins a product
catalogue with a live quote from `quotes`, keeps a 160MB price cache that takes
12 seconds to warm, writes its state to a named volume at `/data`, and runs as
uid 10001. `quotes` serves the quotes. Everything is in your working directory.

You cannot memorise the answer. You can memorise the ladder.

## Your objectives

1. Make `./deploy.sh` succeed, by repairing what was broken — in the
   Dockerfile, `.dockerignore` or `compose.yaml`. The application files
   (`app.py`, `quotes.py`, `catalog.json`) are not what broke; leave them alone.
2. Write `answers/triage.md` with three lines:

   ```
   cause: <what was wrong, in a sentence>
   evidence: <the command, and the field or line in its output, that proved it>
   detection: <a signal and a threshold that would have paged before a user did>
   ```

## What you're being graded on

**The deploy goes healthy** from an empty volume: the grader tears the stack
down, runs the same `up --wait` as `deploy.sh`, and `GET /quote` returns the
catalogue joined with a quote.

**You repaired it rather than routed around it.** Each of these makes the
symptom go away and leaves the fault in place, and each is rejected:

- running `api` as root, or a world-writable `/data`
- no memory limit, a limit over the 512MB budget, or a smaller `CACHE_MB`
- a health check that is not `/ready`, is disabled, or takes more than 10s of
  failures to notice a dead container; a shorter `WARMUP_SECONDS`
- reaching `quotes` by anything but `http://quotes:8000` — `localhost`,
  `host.docker.internal`, `network_mode: host`
- a bind mount that supplies what the image should contain
- editing the application

**The red herring survives.** `quotes` logs an `ERROR` about its eu-west feed
on every request. It has for months, and it serves every quote anyway. It is
not the fault in any draw, and editing it out fails the check.

**You can say what it was.** `cause` is matched against the seeded fault,
`evidence` has to name something that shows that fault, and `detection` has to
name a signal that moves for it and a number to alert at.

<details>
<summary>Hint 1 — the ladder, outside in</summary>

Each rung answers one question. Stop at the first one that explains it.

```
$ docker compose -p devopslings-container-triage ps -a
$ docker inspect -f '{{.State.Status}} restarts={{.RestartCount}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}}' devopslings-container-triage-api-1
$ docker inspect -f '{{json .State.Health}}' devopslings-container-triage-api-1
$ docker compose -p devopslings-container-triage logs api
$ curl -s localhost:18094/ready
$ docker compose -p devopslings-container-triage exec api sh
```

`ps` says whether it is crashing or running-but-unhealthy. Those are two
different halves of the ladder.

</details>

<details>
<summary>Hint 2 — crashing, or running and not ready?</summary>

A climbing restart count means the process dies. Then the question is how:
a traceback in the logs is the app telling you, and exit 137 with nothing in
the logs is the kernel not letting it.

A running container that is unhealthy is the health check telling you. Run it
yourself — `curl localhost:18094/ready` — and read the body, not just the
status. Then run it again twenty seconds later. An answer that changes on its
own is a different problem from one that never does.

</details>

<details>
<summary>Hint 3 — where each fix lives</summary>

- a limit is in `compose.yaml` (`mem_limit` and `memswap_limit` together)
- startup grace for a health check is `start_period`, not more retries
- a service reaches another by service name and *container* port; published
  ports are for the host
- who owns a fresh named volume is decided by the mount point in the image
- what the image contains is decided by the build context, and `.dockerignore`
  decides the context

</details>

## What actually happened

One of five. Which one is in `.drill/state` as a digest, not a word — reading
it teaches nothing.

| Fault | What was done | The rung that shows it |
|---|---|---|
| `oom` | `mem_limit: 128m` under a 160MB cache, swap pinned to the limit | `inspect`: `OOMKilled=true`, exit 137, restarts climbing; logs stop mid-startup with no error |
| `warmup` | the health check has no `start_period` | `Health.Log`: `503 warming` three times in six seconds; `/ready` says `ready` after 12s |
| `dns` | `QUOTES_URL: http://localhost:18095` | `/ready` says `quotes unreachable at http://localhost:18095: Connection refused` |
| `uid` | the Dockerfile no longer creates `/data` owned by `app` | logs: `PermissionError: [Errno 13]` on `/data/state.json`; `stat /data` says uid 0 |
| `context` | `*.json` in `.dockerignore` | logs: `FileNotFoundError: catalog.json`; the image has no such file |

Three crash and two run. Of the three that crash, two tell you in the logs and
one — the OOM kill — leaves the logs looking as if the process simply stopped
talking. Of the two that run, one fixes itself after twelve seconds if the
check is patient enough, and one never does. That is the whole ladder.

<details>
<summary>Solution</summary>

Walk the ladder, then repair at the rung that answered.

```bash
./deploy.sh || true
docker inspect -f '{{.State.OOMKilled}} {{.RestartCount}}' devopslings-container-triage-api-1
docker compose -p devopslings-container-triage logs api | tail -5
curl -s localhost:18094/ready
```

- **oom** — `true` and a restart count: raise the limit to fit the cache plus
  the interpreter, inside the budget: `mem_limit: 256m`, `memswap_limit: 256m`.
- **context** — `FileNotFoundError: catalog.json`: remove `*.json` from
  `.dockerignore` (or add `!catalog.json` after it).
- **uid** — `PermissionError` on `/data`: give the mount point to the app user
  in the image, so a fresh volume copies that ownership:
  `RUN useradd --uid 10001 --create-home app && install -d -o app -g app /data`.
- **dns** — `/ready` names `localhost:18095`: `QUOTES_URL: http://quotes:8000`.
- **warmup** — `/ready` says `warming`, then `ready`: add `start_period: 30s`
  to the health check.

Then, for example:

```
cause: no start_period on the health check; 3 x 2s of 503 ends before the 12s warm-up
evidence: docker inspect .State.Health log shows 503 warming; curl /ready says ready after 12s
detection: alert when time to healthy on deploy exceeds 45 seconds
```

</details>

## Carrying this forward

- **Crashing and unhealthy are different halves of the ladder.** `ps` and the
  restart count split them before you read a single log line.
- **A silent death is a signal.** Logs that stop mid-sentence with exit 137 are
  the kernel, not the app.
- **Read the readiness body, and read it twice.** A check that fails and then
  passes is a timing problem; one that never passes is a dependency.
- **The loudest log line is rarely the fault.** An error that was there
  yesterday, when everything worked, is background.
