---
title: "the build broke and nothing in the repo changed"
---

## The situation

CI built `shop/web` from commit `4be1e0c` twice. Build 1041, yesterday
afternoon, was green. Build 1042, this morning, same commit, is red:

```console
$ tail -4 /work/shop-web/ci/builds/1042.log
0.132 render: unknown option --in (usage: render TEMPLATE > FILE)
ERROR: failed to solve: process "/bin/sh -c render --in /src/index.tmpl --out /www/index.html" did not complete successfully: exit code: 2
result: failure
```

Someone has already rerun it with `--no-cache`, twice. Someone else wants to
change the `render` line to the new syntax and move on. Before anybody does,
read the first line of the Dockerfile:

```dockerfile
FROM 127.0.0.1:15000/upstream/runtime:2
```

`upstream/runtime` is an image another team publishes, the way Docker Hub's
official images are published to you. You can pull it, but you do not control
it.

## Your objectives

1. Find out exactly which base image build 1041 used, and which one 1042 used.
2. Change the Dockerfile so the build uses the base build 1041 was green on,
   and keeps using it no matter what upstream pushes to any tag.
3. Leave `site/` and the `render` step as they are — the template rendered by
   runtime 2.4.1 is what was tested.

## What you're being graded on

The grader builds `/work/shop-web` the way CI does — `--pull`, no cache — and
requires a green build on runtime 2.4.1, serving the rendered page. Then it
acts as upstream: it publishes runtime 2.6.0 and pushes it to **every** tag in
`upstream/runtime`, including the version tags, and builds again. The second
build must be identical in what it runs on. Every `FROM` must name its base by
digest. Upstream's tags are put back afterwards.

<details>
<summary>Hint 1 — what the logs already know</summary>

BuildKit resolves every tag to a digest before it pulls, and says so:

```console
$ grep FROM /work/shop-web/ci/builds/104*.log
```

Then ask the registry what those digests are, and what the tags point at now:

```console
$ crane ls 127.0.0.1:15000/upstream/runtime
$ crane digest 127.0.0.1:15000/upstream/runtime:2.4.1
$ crane config 127.0.0.1:15000/upstream/runtime@sha256:… | jq .
```

</details>

<details>
<summary>Hint 2 — which hash</summary>

`docker images --digests` and `docker inspect` will also show you hashes, and
not all of them are the one a `FROM` line needs. A reference by digest names a
**manifest**: the digest `crane digest` prints, the one in BuildKit's log
line. The *image ID* `docker images` prints is the digest of the image's
config, and no registry will resolve it.

</details>

<details>
<summary>Solution</summary>

```console
$ cd /work/shop-web
$ grep -o 'runtime:2@sha256:[0-9a-f]*' ci/builds/1041.log
runtime:2@sha256:26fc7f89…
$ grep -o 'runtime:2@sha256:[0-9a-f]*' ci/builds/1042.log
runtime:2@sha256:03b96b0f…
$ crane digest 127.0.0.1:15000/upstream/runtime:2.4.1
sha256:26fc7f89…
```

Same tag, two digests: upstream moved `2` from 2.4.1 to 2.5.0 overnight.
Pin the one 1041 used:

```dockerfile
FROM 127.0.0.1:15000/upstream/runtime@sha256:26fc7f89…
```

`FROM …/runtime:2.4.1@sha256:26fc7f89…` is equivalent and reads better: when a
reference carries both, the digest wins and the tag is only a comment.

### The part worth remembering

**A tag is a pointer someone else can move.** That includes version tags.
Official images are rebuilt under the same `3.12.4-slim` tag whenever Debian
ships a security fix, which is usually what you want and occasionally breaks
you. Pinning `:2.4.1` instead of `:2` narrows how often it happens; it does
not stop it, and the grader's last build proves it.

**A digest is the content.** It is a hash of the manifest, which lists the
config and layers by their own hashes, so it cannot name different bytes
tomorrow. The registry can stop serving it — retention, or zot's habit of
dropping a manifest when its last tag moves — but it can never serve
something else under it. A failure you can see is the right failure.

**Pinning makes updates a decision instead of an accident.** The price of a
digest pin is that security fixes stop arriving on their own. That is a
trade you make on purpose: Renovate or Dependabot watch the tag, and when it
moves they open a pull request that changes the digest, so the new base goes
through CI and review like any other change. Build 1042 would have been a red
pull request instead of a red main branch.

**`--no-cache` was never going to help.** The cache was not wrong; it was
faithfully rebuilding against what `2` meant that morning. A build that
depends on a tag is only reproducible for as long as the tag holds still.

</details>
