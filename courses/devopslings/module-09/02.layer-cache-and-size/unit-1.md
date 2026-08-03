---
title: "Every commit rebuilds the world, and the image is 1 GB"
---

## The situation

Two complaints about the same Dockerfile.

From the developers: CI takes six minutes on a one-line change, and it feels
like the build starts from nothing every time.

From whoever pays for the registry: the image is 1.16 GB for a Flask app that
is forty lines long.

```
$ docker build -t devopslings-size .
$ docker images devopslings-size
REPOSITORY         TAG      SIZE
devopslings-size   latest   1.16GB
```

Both complaints have the same root: the Dockerfile does not distinguish between
what you need to *build* the app and what you need to *run* it, and it does not
order its layers by how often they change.

## Your objectives

1. Get the image under 250 MB.
2. Make a one-line change to `app.py` not reinstall the dependencies.
3. Keep it working — `GET /health` must still return `{"status": "ok"}`.

Objective 3 is not filler. Both of the other fixes have a popular wrong version
that produces a small, fast, broken image.

## What you're being graded on

Image size, whether a source change invalidates the dependency layer, and
whether the container still serves `/health`.

<details>
<summary>Hint 1 — see which layers are being rebuilt</summary>

```
docker build --progress=plain -t devopslings-size .
```

Plain progress prints every step. Steps reused from cache are marked `CACHED`;
steps that actually ran show their output.

Build once, then append a comment to `app.py`, then build again and compare.
Note the first step that stops saying `CACHED` — everything from there down
re-runs, because a layer's cache key includes every layer above it.

</details>

<details>
<summary>Hint 2 — the ordering rule</summary>

Put instructions in order of how often their inputs change, least-frequently
first.

`requirements.txt` changes a few times a month. `app.py` changes several times
a day. Right now a single `COPY . .` brings both in at once, so the pip install
below it is invalidated by any source edit.

Copy the dependency manifest on its own, install, and only then copy the source.

</details>

<details>
<summary>Hint 3 — the toolchain is a build-time need</summary>

`build-essential`, `gcc`, `g++` and `make` are around 800 MB and are used to
compile native extensions during `pip install`. The running app never invokes
them.

A multi-stage build lets you keep them in a stage that gets thrown away:

```dockerfile
FROM python:3.12 AS builder
# ... compile here ...

FROM python:3.12-slim
COPY --from=builder /some/path /some/path
```

Only the last stage is shipped. Also compare `python:3.12` (about 1 GB) with
`python:3.12-slim` (about 130 MB) and check whether you need the difference.

</details>

<details>
<summary>Solution</summary>

```dockerfile
FROM python:3.12-slim AS builder
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
WORKDIR /app
COPY --from=builder /install /usr/local
COPY app.py .
CMD ["python3", "app.py"]
```

And a `.dockerignore`, so local junk does not enter the build context and bust
the cache:

```
__pycache__/
*.pyc
.git/
```

```
$ docker images devopslings-size
REPOSITORY         TAG      SIZE
devopslings-size   latest   149MB
```

1158 MB → 149 MB, and editing `app.py` no longer reinstalls Flask.

### What each change bought

**`python:3.12-slim` instead of `python:3.12`** — the full image carries a
complete build toolchain and a lot of documentation. Most of the saving is here.

**Multi-stage** — dependencies are installed into `/install` in the builder and
copied into a clean final stage. Anything the builder needed and the runtime
does not is discarded with the stage.

**`COPY requirements.txt` before `COPY app.py`** — this is what fixes the cache.
Docker layers are content-addressed and stacked: changing a layer invalidates
every layer below it. With `COPY . .` above the install, any source edit changes
that layer's hash and the install below is rebuilt. Copying the manifest
separately means the install layer's inputs only change when the manifest does.

**`--no-cache-dir`** — pip's download cache is useless in an image and costs
tens of megabytes.

### The wrong versions that still "work"

- **`pip install --user` in the builder, then copying `/root/.local`** — works
  until the final stage runs as a different user and cannot find the packages.
- **Squashing everything into one `RUN`** — makes the image smaller and makes
  the cache useless, because now *every* change rebuilds *everything*. It trades
  one complaint for the other.
- **Copying `/usr/local/lib/python3.12/site-packages` between different base
  images** — packages with compiled extensions are linked against the libc and
  Python ABI of the image that built them. Same base image in both stages, or it
  breaks at import time in a way that looks like a Python bug.

### The general rule

Order layers by change frequency, and ship only what runs. Both complaints in
this lesson came from violating those two rules with a single `COPY . .` and a
single base image.

</details>
