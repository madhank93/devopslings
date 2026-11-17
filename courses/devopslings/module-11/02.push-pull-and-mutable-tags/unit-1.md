---
title: "production changed, and nobody deployed"
---

## The situation

Release 1.4.0 of the shop went out on Monday. Production is one container,
deployed from `/work/deploy/compose.yaml`:

```yaml
services:
  web:
    image: 127.0.0.1:15000/shop/web:latest
    pull_policy: always
```

On Tuesday CI built a release candidate with debug logging switched on. CI
pushes every build to its version tag and to `latest`, as it always has. On
Wednesday the nightly restart ran `deploy.sh`, and production now says:

```console
$ curl -s shop-web:8080
<h1>shop 1.5.0-rc1-debug</h1>
```

Nobody deployed 1.5.0. Nobody had to.

## Your objectives

1. Put production back on release 1.4.0.
2. Make sure the next build CI pushes to `latest` cannot change what
   production runs, however many times `deploy.sh` is run afterwards.

Keep deploying through `/work/deploy/deploy.sh`, because the nightly restart
runs it too.

## What you're being graded on

That `shop-web` is running the image release 1.4.0 names. Then the grader acts
as CI: it pushes a new build to `latest`, runs `deploy.sh`, and checks that
production did not move. The deploy file also has to name the release in a form
that cannot be moved — a version tag is still a tag. The grader puts `latest`
back where it found it afterwards.

<details>
<summary>Hint 1 — the restart is not the bug</summary>

`pull_policy: always` asks the registry what `latest` means on every deploy, and
that is reasonable — a deploy that silently keeps a stale local image is a
different incident. The problem is the question. "What is `latest` now?" has a
different answer after every CI run.

Re-tagging 1.4.0 as `latest` and redeploying fixes production for exactly as
long as CI stays idle.

</details>

<details>
<summary>Hint 2 — ask the registry once, and write the answer down</summary>

```console
$ docker login 127.0.0.1:15000 -u devops
$ crane digest 127.0.0.1:15000/shop/web:1.4.0
sha256:…
```

Compose, Kubernetes, `docker run` and every other client accept
`name@sha256:<digest>` wherever they accept `name:tag`.

</details>

<details>
<summary>Solution</summary>

```console
$ crane digest 127.0.0.1:15000/shop/web:1.4.0
sha256:4be1…
```

```yaml
services:
  web:
    image: 127.0.0.1:15000/shop/web@sha256:4be1…
    container_name: shop-web
    pull_policy: always
    restart: unless-stopped
```

```console
$ /work/deploy/deploy.sh
$ curl -s shop-web:8080
<h1>shop 1.4.0</h1>
```

`pull_policy: always` can stay. A pull by digest asks the registry for one
specific manifest, and the answer is either those bytes or an error — never
different bytes.

### The part worth remembering

**Deploy digests, publish tags.** Tags are for people: `1.4.0` is what goes in
the release notes and what someone types. A digest is what a machine should
deploy, because it is the only name that refers to content rather than to
whatever was pushed there last. The usual pattern is to resolve the tag once, at
release time, and write the digest into the deploy config — in a pull request,
so the change of version has a diff and an author.

`name:1.4.0@sha256:…` is also legal. The tag is ignored for pulling and kept for
humans, which makes it the friendliest form to review.

**`latest` is a convention, not a guarantee.** It is the tag you get when you
type none, and it means "pushed here most recently". In this incident that was a
debug build that nobody released. A pipeline that pushes every build to
`latest` turns any deploy following `latest` into a continuous-deployment
pipeline nobody designed.

**Registries can also refuse the move.** Harbor has *tag immutability* rules
(per project, by tag pattern), and ECR has an `IMMUTABLE` setting per
repository: a push to an existing tag is rejected instead of moving it. Those
are worth having for release tags, and they are a second line. They do not help
with `latest`, which exists to be moved, and they only protect clients that
pull from that registry — a pinned digest protects the deploy wherever the
image comes from.

**A pinned digest is only as durable as the registry's memory of it.** The
digest above keeps working because `1.4.0` still points at it. In this sandbox
(zot), a manifest that loses its last tag is removed from the repository at
once; in Harbor and Distribution it lingers untagged until garbage collection or
retention removes it. Either way, a digest that production depends on needs a
tag that keeps it alive. The next lesson is a retention policy that did not.

</details>
