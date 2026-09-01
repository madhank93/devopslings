---
title: "the summarizer stopped writing the day it stopped running as root"
---

## The situation

The security review had one finding about this service: it runs as root. That
was a two-line change to the Dockerfile — add a user, `USER appuser` — and the
image still builds, still starts, and now does nothing at all:

```
$ docker compose -p devopslings-uid-mismatch up --build
exporter-1    | exported 5 events
exporter-1 exited with code 0
summarizer-1  | running as uid 10001
summarizer-1  | Traceback (most recent call last):
summarizer-1  |   File "/app/summarize.py", line 16, in <module>
summarizer-1  |     os.makedirs(os.path.dirname(OUT), exist_ok=True)
summarizer-1  | PermissionError: [Errno 13] Permission denied: '/data/out'
summarizer-1 exited with code 1
```

`/data` is a named volume, shared with the exporter. It has always been there.
Nothing about the volume changed. The only thing that changed is who is asking.

The obvious next move — `chmod -R 777 /data` in an init step — makes the error
go away, and the reviewer who wrote the finding will reject it. Both of those
are true at once, and the second is the point of the lesson.

## Your objectives

1. Make `summarizer` finish and write `/data/out/summary.txt`, while still
   running as a non-root user.
2. Leave the volume owned by that user — all of it, including what the exporter
   wrote — with nothing on it writable by everyone.

Keep the services named `exporter` and `summarizer`, and keep them sharing a
named volume at `/data`: that shared volume is the thing under repair. Treat
`exporter` as a vendor image you cannot rebuild — you can change how it is run,
not what is inside it.

## What you're being graded on

That `summarizer` exits 0 and reports a non-root uid of its own; that the
summary on the volume is the one `summarize.py` writes; that every path on the
volume belongs to the uid the app actually ran as; and that no path on it is
world-writable. Which non-root uid you settle on is yours to choose — the
grader takes the uid the app reports and holds the volume to that.

<details>
<summary>Hint 1 — look at the volume, not the app</summary>

The app is telling the truth: it cannot write there. Go and see what "there"
looks like, with a container that can read it:

```
docker run --rm -v devopslings-uid-mismatch_reports:/data \
  alpine:3.20 stat -c '%u %g %a %n' /data /data/incoming
```

`%u` is the owning uid. Compare it to the uid in the summarizer's own log line.

</details>

<details>
<summary>Hint 2 — who decided that</summary>

A fresh named volume starts as an empty directory owned by root, mode 755. From
there, ownership is whatever the containers that write to it make it: the
exporter runs as root, creates `/data/incoming`, and the volume is now a
root-owned tree that a uid-10001 process may read and may not write.

Nothing in the compose file says "root owns this". It is a side effect of which
container got there first.

</details>

<details>
<summary>Hint 3 — the shape of the fix</summary>

Something has to run as root, once, and hand the volume over — after the
exporter has written to it and before the summarizer needs it. Compose can
order a one-shot service:

```yaml
  depends_on:
    exporter:
      condition: service_completed_successfully
```

`chown` changes who owns a path. `chmod 777` changes nothing about who owns it
and lets every container that ever mounts this volume write to it. You want the
first one.

</details>

<details>
<summary>Solution</summary>

Look at the volume:

```
$ docker run --rm -v devopslings-uid-mismatch_reports:/data \
    alpine:3.20 stat -c '%u %g %a %n' /data /data/incoming
0 0 755 /data
0 0 755 /data/incoming
```

Root owns it, and 755 gives everyone else read and execute and nothing more.
The summarizer runs as 10001 and needs to create `/data/out`. It cannot.

Add a one-shot service between the two that hands the tree over:

```yaml
  fixperms:
    image: alpine:3.20
    command: ["chown", "-R", "10001:10001", "/data"]
    depends_on:
      exporter:
        condition: service_completed_successfully
    volumes:
      - reports:/data

  summarizer:
    build: .
    depends_on:
      fixperms:
        condition: service_completed_successfully
    volumes:
      - reports:/data
```

```
$ docker compose -p devopslings-uid-mismatch down -v
$ docker compose -p devopslings-uid-mismatch up --build
exporter-1    | exported 5 events
fixperms-1 exited with code 0
summarizer-1  | running as uid 10001
summarizer-1  | wrote /data/out/summary.txt
summarizer-1 exited with code 0
```

`down -v` matters while you are working on this. Ownership is set by whatever
touched the volume first, so a volume left over from an earlier attempt can make
a broken compose file look fixed, and a fixed one look broken.

### The part worth remembering

The kernel checks uids, not usernames. `appuser` inside the container and
`appuser` on the host are unrelated strings; `10001` is the only part that
crosses the boundary. A file written by a container "belongs to appuser" only in
the sense that some `/etc/passwd` maps 10001 to that name — and the volume, the
host, and the next image each have their own opinion about that mapping, or
none at all.

Where a fresh named volume's ownership comes from, in order:

- If the image of the **first container to mount it** already has that directory,
  Docker copies its contents *and its ownership* into the empty volume. So a
  `RUN mkdir -p /data && chown appuser /data` in that image pre-owns the volume
  with no init step at all. Here it would not be enough: the first container to
  mount `/data` is the exporter, and the files it writes afterwards are root's
  either way.
- Otherwise the volume root is root-owned, 755, and stays that way until
  something changes it.
- A **bind mount** gets none of this. The host directory's ownership is what the
  container sees, unchanged.

Which is why this bug is close to invisible on a Mac laptop: Docker Desktop and
OrbStack remap ownership on bind mounts so that whatever the container writes
comes back owned by you. The same compose file on a Linux CI runner or a
production host does exactly what it says. If you have ever heard "works on my
machine" about file permissions, this is usually it.

The three fixes you will see in the wild, and when each is right:

- **An init step that chowns**, as above. Correct when something else — a vendor
  image, a restored backup, an older release — put files there as root.
- **Pre-owning the directory in the image**, so the volume is seeded correctly.
  The cleanest option when your image is the only writer.
- **`user:` on the service**, aligning the uid instead of the files. Right when
  the data has an owner you cannot change and you can choose your process's uid.

`chmod -R 777` is none of them. It grants write to every process in every
container that mounts the volume, now and later, which is the same permission
model you had when everything ran as root — with the audit trail of having
thought about it.

In Kubernetes these have direct equivalents: `securityContext.runAsUser` is
`user:`, `fsGroup` is the chown, and an `initContainer` is `fixperms`. Same
problem, same three answers, different spelling.

</details>
