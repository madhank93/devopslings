---
title: "the build spends most of its time before the first instruction runs"
---

## The situation

The service is four files and a Dockerfile. The build on the CI runner takes
most of a minute, and the part that takes the longest happens before any
instruction runs:

```
$ docker build -t devopslings-context .
#5 [internal] load build context
#5 transferring context: 106.10MB 0.3s done
#6 [2/3] COPY . .
```

106 megabytes, for an app that is a hundred lines. On your laptop that transfer
is a third of a second, which is why nobody has looked at it. On a runner with
a remote daemon it is the build.

And it does not stop at the transfer. The image is 106 MB bigger than it needs
to be, because `COPY . .` copied all of it in:

```
$ docker image inspect -f '{{.Size}}' devopslings-context
258542720
```

The working directory has `.git`, the frontend's `node_modules`, a virtualenv,
test fixtures and a build log in it. None of that is in the image's job
description.

## Your objectives

1. Get the build context under 1 MB.
2. Keep the image working: it reads `templates/index.html` and
   `web/dist/bundle.js` at runtime and prints both.

## What you're being graded on

The grader measures the context the way the daemon receives it — everything
that gets uploaded, independent of which parts any `COPY` line asks for — and
requires it under 1 MB. Then it builds the image and runs it, and expects both
files to still be there.

<details>
<summary>Hint 1 — find out what is actually being sent</summary>

The build output names the number:

```
#5 transferring context: 106.10MB
```

And this tells you where it is coming from:

```
du -sk .[!.]* * | sort -rn | head
```

Compare that list against what the image needs at runtime.

</details>

<details>
<summary>Hint 2 — the obvious fix does not fix it</summary>

Replacing `COPY . .` with a few narrow `COPY` lines makes the *image* smaller
and leaves the transfer exactly where it was.

Worth proving to yourself rather than taking on faith: change the Dockerfile to
copy only `app.py`, build again, and read the `transferring context` line. Then
work out what the ordering must be — which happens first, the client reading
your Dockerfile, or the client sending the directory.

</details>

<details>
<summary>Hint 3 — the file that is read before the upload</summary>

`.dockerignore`, in the context root. One pattern per line, matched against
paths relative to that root:

```
build/
*.tmp
**/some-dir
```

`**/` matches at any depth, which is what you want for a directory that appears
in more than one place. Exclude too much and the image loses a file it reads at
runtime, so check what the app actually opens before you write the list.

</details>

<details>
<summary>Solution</summary>

```
.git
**/node_modules
.venv
fixtures
tmp
*.log
```

```
$ docker build -t devopslings-context .
#4 transferring context: 297B done

$ docker run --rm devopslings-context
index: <h1>devopslings</h1>
bundle: console.log("bundle v3");

$ docker image inspect -f '{{.Size}}' devopslings-context
152472750
```

106.10 MB of context became 297 bytes, and the image dropped to the size of its
base plus the app.

### The part worth remembering

`docker build .` is two programs. The **client** packs the directory named by the
final argument into a tar and uploads it to the **daemon**; the daemon then reads
the Dockerfile and runs the instructions. The upload is finished before the first
instruction is read, which is why no `COPY` line can influence it. `.dockerignore`
is the only thing that can, because the client reads it first and leaves the
matching paths out of the tar.

Consequences worth carrying:

- **`.gitignore` is not consulted.** They are different files with similar
  syntax, and a directory that is untracked is still uploaded. Repos usually
  need both, and they usually differ: `.git` itself belongs in `.dockerignore`
  and obviously not in `.gitignore`.
- **What is in the context is available to be copied.** `COPY . .` in a
  directory holding a `.env`, a `.npmrc`, a private key, or `.git` puts all of
  it in the image — including, via `.git`, every version of every file ever
  committed. This is `secrets-in-layers` arriving by a different road.
- **The context is part of the cache key.** A `.git` directory that changes on
  every commit invalidates `COPY . .` on every commit, which is half of what
  `layer-cache-and-size` was about. Excluding it makes the cache behave.
- **Patterns are matched by the daemon's own matcher**, not by a shell: `*` does
  not cross a `/`, `**` does, a leading `!` re-includes something an earlier line
  excluded, and later lines win. `!` is how you write "none of `web` except
  `web/dist`".

The habit that avoids this entirely: write `.dockerignore` when you write the
Dockerfile, starting from the position that nothing is sent, and add back what
the build needs.

</details>
