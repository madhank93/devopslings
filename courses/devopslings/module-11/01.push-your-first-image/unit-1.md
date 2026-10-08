---
title: "push an image, then find it again"
---

## The situation

There is a two-line web page in `/work/hello`, and a Dockerfile that serves it
with busybox's `httpd`. Nobody has built it yet. There is a registry at
`127.0.0.1:15000` with nothing in it.

By the end of this lesson the registry will hold two builds of that page, and
you will know three different names for each of them — one of which is
reliable.

## Your objectives

1. Log in to the registry as `devops` / `devopslings`.
2. Build `/work/hello` and push it as `127.0.0.1:15000/hello/web:1.0` **and**
   as `127.0.0.1:15000/hello/web:latest`.
3. Record in `/work/answer.txt`, as `first=`, the digest `latest` points at now.
4. Change `index.html`, build again, and push the new image as `1.1` and as
   `latest`.
5. Record, as `second=`, the digest `latest` points at now.

## What you're being graded on

The grader is a second client: it has never built either image, and it asks
the registry directly. It checks that `1.0`, `1.1` and `latest` exist, that
your two digests are the ones the registry serves under those names, and that
pulling each digest unpacks to a different `index.html`.

<details>
<summary>Hint 1 — a registry address is part of the name</summary>

An image name has the registry in front of it. `hello/web:1.0` on its own means
Docker Hub; to send it here the tag has to start with `127.0.0.1:15000/`.

```console
$ docker login 127.0.0.1:15000 -u devops
$ docker build -t 127.0.0.1:15000/hello/web:1.0 -t 127.0.0.1:15000/hello/web:latest /work/hello
$ docker push 127.0.0.1:15000/hello/web:1.0
$ docker push 127.0.0.1:15000/hello/web:latest
```

`-t` can be given more than once. Both names are for one image.

</details>

<details>
<summary>Hint 2 — which sha256 is the digest</summary>

Look at the image three ways and you will see two different hashes:

```console
$ docker images 127.0.0.1:15000/hello/web
$ docker push 127.0.0.1:15000/hello/web:latest      # read the last line
$ crane digest 127.0.0.1:15000/hello/web:latest
```

`docker images` prints an **image ID**. `docker push` and `crane digest` print
the **digest**. Only one of them means anything to the registry — try
`crane manifest 127.0.0.1:15000/hello/web@<each one>` and see which it knows.

</details>

<details>
<summary>Solution</summary>

```console
$ docker login 127.0.0.1:15000 -u devops          # password: devopslings
$ cd /work/hello
$ docker build -t 127.0.0.1:15000/hello/web:1.0 -t 127.0.0.1:15000/hello/web:latest .
$ docker push 127.0.0.1:15000/hello/web:1.0
$ docker push 127.0.0.1:15000/hello/web:latest
latest: digest: sha256:5c1e… size: 734
$ crane digest 127.0.0.1:15000/hello/web:latest   # same value: put it in first=

$ echo '<h1>hello, version two</h1>' > index.html
$ docker build -t 127.0.0.1:15000/hello/web:1.1 -t 127.0.0.1:15000/hello/web:latest .
$ docker push 127.0.0.1:15000/hello/web:1.1
$ docker push 127.0.0.1:15000/hello/web:latest
$ crane digest 127.0.0.1:15000/hello/web:latest   # a new value: second=
```

Then check it the way the grader does, without the daemon's cache in the way:

```console
$ crane export 127.0.0.1:15000/hello/web@sha256:5c1e… - | tar -xO www/index.html
<h1>hello, version one</h1>
```

### The part worth remembering

An image in a registry has three kinds of name, and they behave differently.

- **A tag** (`:latest`, `:1.1`) is a pointer the registry stores, and anyone
  with push access can move it. `latest` is not special — it is the tag you get
  when you do not type one, and it means "whatever was pushed here last", which
  is not the same thing as "newest". `1.0` behaves identically; it only stays
  put because people agree not to push to it again.
- **A digest** (`@sha256:…`) is the sha256 of the image's manifest — the
  document listing its config and every layer by *their* digests. Change one
  byte anywhere in the image and the digest changes, so a digest cannot be
  moved. It can only exist or not exist.
- **The image ID** that `docker images` prints is the digest of the image's
  *config*, the daemon's local identifier. It is stable for an image across
  pushes, which makes it look like the right answer, and the registry has never
  heard of it.

`docker push` printing a digest is how the registry tells you what it stored.
That value is the one to write into a deploy, a rollback note, an incident
timeline or a signature — the next lesson is what happens to a deploy that
wrote down a tag instead.

**What a registry keeps is a registry decision.** When a tag moves, the
manifest it used to point at becomes *untagged*. Distribution (`registry:2`),
Harbor, GHCR and ECR keep untagged manifests until garbage collection or a
retention rule removes them; zot, the registry in this sandbox, drops an
untagged manifest from the repository's index as soon as the tag moves. That is
why this lesson gives each build a version tag as well as `latest`: the build
you can still pull by digest is the one something still references. Lesson 3
makes that rule into a policy.

</details>
