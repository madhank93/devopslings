---
title: "the license key is in the image, and deleting the file did not remove it"
---

## The situation

The renderer ships with a licensed sprite atlas. The atlas is encrypted in the
repository and the build decrypts it, so the build needs the license key. CI
passes it the way everyone passes things to a build:

```
docker build --build-arg LICENSE_KEY="$(cat license.key)" -t devopslings-licensed .
```

It works. The image runs. And then someone pulls the published image and types
this:

```
$ docker history --no-trunc devopslings-licensed
RUN |1 LICENSE_KEY=lic_9f4b21c0e7d3_devopslings /bin/sh -c echo "$LICENSE_KEY" > /root/.license # buildkit
ARG LICENSE_KEY=lic_9f4b21c0e7d3_devopslings
```

The key is in the image. Not in a file in the image — in the image's *metadata*,
which travels with every pull, needs no unpacking, and is readable by anyone who
can pull.

## Your objectives

1. Keep the build working: the image must still decrypt `assets.enc` and print
   the licensed asset when it runs.
2. Make the key appear nowhere in the published image — not in `docker history`,
   not in the image config, not in any layer.

The key stays what it is: `license.key` is the credential CI holds, and this
exercise is not about changing it. Do the decrypting inside the build — unpacking
the atlas on your laptop and copying the plaintext in answers a different
question.

`build.sh` is what CI runs, and it is what the grader runs. If your build needs
different arguments, put them there.

## What you're being graded on

That `build.sh` builds `devopslings-licensed`, that running it prints the
licensed asset, and that the key appears in neither the image's history nor any
of its layers. The grader searches the whole saved image, not just the
filesystem you can see.

<details>
<summary>Hint 1 — two hiding places, not one</summary>

An image is layers plus metadata, and the key can be in either:

```
key=$(cat license.key)
docker history --no-trunc devopslings-licensed | grep "$key"   # the metadata
docker save devopslings-licensed | grep -ac "$key"             # layers included
```

Run both before and after any change you make. A fix that cleans one and not
the other is the interesting failure here.

</details>

<details>
<summary>Hint 2 — what a later instruction can and cannot undo</summary>

The tempting move is `RUN rm -f /root/.license` at the end.

Think about what a layer is: the set of changes one instruction made, stored as
its own snapshot. What does adding a snapshot that says "this file is deleted"
do to the earlier snapshot that contains it? What is `docker save` going to
find?

</details>

<details>
<summary>Hint 3 — give the build the secret without giving the image the secret</summary>

BuildKit can mount a file into a single `RUN`, present while that command runs
and gone afterwards, recorded nowhere:

```dockerfile
RUN --mount=type=secret,id=license \
    some-command /run/secrets/license
```

```
docker build --secret id=license,src=license.key -t devopslings-licensed .
```

`unpack.py` already takes the *path* to the key rather than the key itself,
which is what makes this a two-line change.

</details>

<details>
<summary>Solution</summary>

```dockerfile
FROM python:3.12-slim
WORKDIR /app
COPY unpack.py assets.enc app.py ./
RUN --mount=type=secret,id=license \
    python3 unpack.py /run/secrets/license assets.enc /app/assets.txt
CMD ["python3", "app.py"]
```

```bash
#!/usr/bin/env bash
set -euo pipefail
docker build --secret id=license,src=license.key -t devopslings-licensed .
```

```
$ ./build.sh
$ docker run --rm devopslings-licensed
LICENSED-ASSET-OK sprite-atlas v4

$ key=$(cat license.key)
$ docker history --no-trunc devopslings-licensed | grep "$key"
$ docker save devopslings-licensed | grep -ac "$key"
0
```

The asset is still decrypted by the build. The key was mounted at
`/run/secrets/license` for the length of that one `RUN` — a tmpfs, not a layer —
and neither the mount nor its contents are recorded in the image.

### The part worth remembering

**`--build-arg` is not a secret mechanism.** BuildKit records the build args an
instruction ran with, right there in the history line: `RUN |1
LICENSE_KEY=... `. `ENV` is worse — it is in the image config and also in the
environment of every process the container runs. `docker history` needs no
special access; it is metadata that ships with the image.

**Deleting the file does not delete the file.** Each instruction's layer is an
immutable snapshot of what that instruction changed. A later `rm` adds a
whiteout entry saying the path is gone, which changes what a running container
sees and changes nothing about the layer that still holds the bytes. `docker
save` walks the layers, and so does anyone who wants the key. This is the same
shape as `secret-in-history` in module 08: the tip is clean and the history
carries it. Deleting is not removing, in git or in Docker.

Ways to give a build something it must not keep:

- **`RUN --mount=type=secret`** — the right default. Present for one command, in
  no layer, in no history, and not part of the layer's cache key.
- **A multi-stage build**, doing the privileged work in a builder stage and
  `COPY --from` of only the artefact. The final image is clean, which is what
  gets published. Be aware the builder stage's layers still hold the secret in
  your local build cache, and go with it if you export that cache to a registry.
- **`RUN --mount=type=ssh`** for git-over-SSH dependencies, which forwards an
  agent socket instead of a key file.

**And rotate.** Every fix above changes the *next* image. The key that is in the
published image is published: it is in every pull, in every CI cache, and in
whatever registry mirrors that image. Cleaning the Dockerfile without rotating
the credential leaves the credential compromised — the repair is a new key first,
then a build that does not record it.

</details>
