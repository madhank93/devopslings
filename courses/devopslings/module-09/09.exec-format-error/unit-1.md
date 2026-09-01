---
title: "exec format error on the runner, and the same image is fine on your laptop"
---

## The situation

The pricing agent builds, the image pushes, and the deploy to the runner dies
before the program prints anything:

```
$ docker run localhost:5001/pricing-agent:1
exec /usr/local/bin/app: exec format error
```

On your machine the same tag runs fine. Rebuilding produces the same result.
The error is not from the app — the app never started. It is the kernel
declining to load a binary compiled for a different processor.

The runner is `linux/amd64`. Your laptop may not be.

## Your objectives

1. Publish one tag that carries both `linux/amd64` and `linux/arm64`.
2. Make each of those images contain a binary compiled for the architecture its
   manifest claims.

The second is not implied by the first, and that is the whole lesson.

`build.sh` is what CI runs, and it is what the grader runs. There is a local
registry at `localhost:5001` standing in for the one the runner pulls from, and
a buildx builder named `devopslings-xarch` that can reach it.

## What you're being graded on

That `build.sh` publishes `localhost:5001/pricing-agent:1` with both platforms
in its manifest; that the binary inside each one is compiled for that platform,
checked by reading the ELF header rather than by trusting the manifest; and that
the image for this machine's architecture still runs and prints
`pricing-agent v1 ok`.

<details>
<summary>Hint 1 — ask what you actually published</summary>

```
docker buildx imagetools inspect localhost:5001/pricing-agent:1
```

A tag can point at a manifest *list*: one entry per platform, and the client
picks the one matching the machine pulling it. Count the entries you have.

`docker buildx build --platform linux/amd64,linux/arm64 --push` produces the
list. `--load` cannot: the local image store holds one image, which is why
multi-platform builds are pushed rather than loaded.

</details>

<details>
<summary>Hint 2 — the manifest is a label, not an inspection</summary>

Once both platforms are published, look at what is actually inside the amd64
one:

```
docker pull --platform linux/amd64 localhost:5001/pricing-agent:1
c=$(docker create --platform linux/amd64 localhost:5001/pricing-agent:1)
docker cp "$c:/usr/local/bin/app" ./app.bin && docker rm "$c"
od -An -tx1 -j18 -N2 app.bin
```

Two bytes at offset 18 of an ELF file name the machine it was compiled for:
`3e 00` is x86-64, `b7 00` is aarch64. Compare that with what the manifest
promised.

</details>

<details>
<summary>Hint 3 — where the binary's architecture is decided</summary>

```dockerfile
FROM --platform=$BUILDPLATFORM golang:1.23-alpine AS build
RUN go build -o /out/app main.go
```

`--platform=$BUILDPLATFORM` pins the builder stage to the machine doing the
building — deliberately, because that is what makes the build fast instead of
emulated. So `go` runs natively and compiles for the machine it is running on.

BuildKit passes the target down as build args. `TARGETOS` and `TARGETARCH` are
declared with `ARG` and are exactly what Go's `GOOS` and `GOARCH` want.

</details>

<details>
<summary>Solution</summary>

Ask for both platforms, and push rather than load:

```bash
docker buildx build --builder devopslings-xarch \
  --platform linux/amd64,linux/arm64 \
  --push -t localhost:5001/pricing-agent:1 .
```

That alone gives a manifest with two entries and an amd64 image that still dies
on the runner, because both passes ran the same native compiler:

```
$ od -An -tx1 -j18 -N2 app.bin      # from the linux/amd64 image
 b7 00                              # aarch64
```

Tell the compiler what it is building for:

```dockerfile
FROM --platform=$BUILDPLATFORM golang:1.23-alpine AS build
ARG TARGETOS TARGETARCH
WORKDIR /src
COPY main.go .
RUN CGO_ENABLED=0 GOOS=$TARGETOS GOARCH=$TARGETARCH go build -o /out/app main.go

FROM alpine:3.20
COPY --from=build /out/app /usr/local/bin/app
CMD ["app"]
```

```
$ docker buildx imagetools inspect localhost:5001/pricing-agent:1
  Platform:    linux/amd64
  Platform:    linux/arm64

$ od -An -tx1 -j18 -N2 app.bin      # from the linux/amd64 image
 3e 00                              # x86-64
```

### The part worth remembering

**An image's architecture is metadata, and nothing checks it against the
contents.** `docker image inspect -f '{{.Architecture}}'` reports what the build
wrote down. The kernel on the runner reads the ELF header instead, and
`exec format error` is what it says when those disagree. The same error turns up
with a `COPY`ed binary built on the host, a base image pulled for the wrong
platform, and a `#!/bin/bash` script in an image with no bash — anything the
loader is handed and cannot execute.

**It runs on your laptop for a reason that will not last.** An arm64 binary in
an amd64-labelled image runs fine on an arm64 machine, because the label is not
consulted when the file is executed locally. Only the machine that does not
share your architecture finds out.

The two build args are the whole cross-compilation vocabulary:

- `BUILDPLATFORM` / `BUILDARCH` — the machine running the build.
- `TARGETPLATFORM` / `TARGETOS` / `TARGETARCH` — what this pass is building for.

`FROM --platform=$BUILDPLATFORM` on the toolchain stage plus `GOARCH=$TARGETARCH`
in the build command is the standard shape for any compiler that cross-compiles
cleanly: one native toolchain, N outputs, no emulation. Drop the
`--platform=$BUILDPLATFORM` and BuildKit runs the whole toolchain under QEMU
instead — correct in principle, considerably slower, and prone to its own
failures inside the emulator.

For interpreted images there is nothing to cross-compile, but the base image is
still per-platform, so a multi-platform build is still what publishes a tag both
architectures can pull. `--load` cannot hold one; a registry is where manifest
lists live, which is why this exercise pushes to one.

</details>
