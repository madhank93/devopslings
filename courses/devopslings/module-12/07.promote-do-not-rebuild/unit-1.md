---
title: "staging and production are running different bytes"
---

## The situation

The pipeline has three jobs and they run in order: build, deploy to staging,
deploy to production. Every run is green. The team tests in staging and then
promotes to production, which is exactly the process everyone agreed on.

Here is the production job:

```yaml
  deploy-production:
    runs-on: docker
    needs: [deploy-staging]
    steps:
      - run: |
          git clone -q http://forge:3000/devops/checkout.git .
          git checkout -q "${{ github.sha }}"
          docker build --build-arg BUILT_AT="..." -t "${IMAGE}:production" .
          docker push "${IMAGE}:production"
```

It checks out the same commit, so it builds the same thing. Ask the registry
what each environment is actually running:

```console
$ for tag in staging production; do
    curl -sI -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
      http://127.0.0.1:5000/v2/checkout/manifests/$tag | grep -i docker-content-digest
  done
docker-content-digest: sha256:9e9e3befed3f45fb936ba47f255931e3afd27425753d70dd9e2a388e2682310a
docker-content-digest: sha256:e1cd26f40bd8e231b663843360b2bf1b45688ce755ce6c0caf770e826c1d0a51
```

Two images. One commit. Whatever staging proved, it proved it about bytes that
are not the ones production is serving.

## Your objectives

1. Make one build per commit, and make both environments point at it.
2. Keep a new commit reaching production — a pipeline where nothing ever
   changes also has staging and production in perfect agreement.

Leave the `BUILT_AT` stamp in the Dockerfile. Recording which build an image
came from is a requirement, not the bug.

## What you're being graded on

That `staging` and `production` resolve to the same manifest digest after a run
finishes. Then the grader pushes a commit changing a constant in
`src/server.js` and requires that both tags move together to a *new* digest,
built under a new `build.id`. It force-pushes the repository back afterwards.

<details>
<summary>Hint 1 — a tag is not an artefact</summary>

`checkout:production` is a name the registry stores a pointer under. The
artefact is the manifest, and its identity is the digest — the sha256 of the
manifest document, which covers the config and every layer.

Two builds of one commit are two artefacts unless every byte that goes into
them is identical, and something almost always is not: a timestamp, a
`node_modules` resolution, a base image that has moved since this morning, a
different builder version. Here it is the `BUILT_AT` argument, which is stamped
into the image on purpose so an incident can be traced back to a build.

"Build it again from the same commit" is a statement about the source. It is
not a statement about the bytes.

</details>

<details>
<summary>Hint 2 — what promotion means</summary>

Build once. Push it under a name that will never point at anything else — the
commit is the obvious one:

```
${IMAGE}:git-${{ github.sha }}
```

Then a deploy is not a build. It is a second name for the artefact that already
exists:

```yaml
- run: |
    docker pull "${IMAGE}:git-${{ github.sha }}"
    docker tag  "${IMAGE}:git-${{ github.sha }}" "${IMAGE}:staging"
    docker push "${IMAGE}:staging"
```

`docker tag` does not touch the image. The push that follows uploads no layers,
because the registry already has them — it writes one more pointer to the same
manifest.

</details>

<details>
<summary>Hint 3 — do not fix it by making the two builds match</summary>

You can also make the digests agree by deleting the timestamp, or by freezing it
to a constant, so that both builds come out byte-identical. The check goes
green and the problem is worse than before: two builds you now cannot tell
apart, and everything else that makes a rebuild non-reproducible is still there
waiting.

Reproducible builds are a real and useful goal. They are not a substitute for
promoting one artefact — they are what makes it *possible* to verify that you
did.

</details>

<details>
<summary>Solution</summary>

```yaml
jobs:
  build:
    steps:
      - run: |
          git clone -q http://forge:3000/devops/checkout.git .
          git checkout -q "${{ github.sha }}"
          docker build --build-arg BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%S)-$$" \
            -t "${IMAGE}:git-${{ github.sha }}" .
          docker push "${IMAGE}:git-${{ github.sha }}"

  deploy-staging:
    needs: [build]
    steps:
      - run: |
          docker pull "${IMAGE}:git-${{ github.sha }}"
          docker tag  "${IMAGE}:git-${{ github.sha }}" "${IMAGE}:staging"
          docker push "${IMAGE}:staging"

  deploy-production:
    needs: [deploy-staging]
    steps:
      - run: |
          docker pull "${IMAGE}:git-${{ github.sha }}"
          docker tag  "${IMAGE}:git-${{ github.sha }}" "${IMAGE}:production"
          docker push "${IMAGE}:production"
```

One `docker build` in the whole file. The environments became names for an
artefact instead of instructions to produce one.

### The part worth remembering

**The artefact is the digest; the tag is a pointer.** `:production` tells you
where to look, not what you have. Anything that has to be exact — a rollback, an
incident timeline, a signature, an SBOM, a vulnerability report — is about a
digest. This is why deployments in a serious pipeline pin
`image@sha256:...` rather than a tag: a tag can be moved by anyone with push
access, including by the next run of your own pipeline.

**"Same commit" is not "same bytes".** A build depends on the commit *and* on
everything the build reads that the commit does not pin: the base image behind
its tag, whatever the package manager resolves today, the clock, the builder.
Every one of those is a real production incident someone has already had. The
guarantee you actually want — what was tested is what is running — comes from
not building twice, not from hoping the second build agrees.

**Promotion should be metadata, not work.** Moving a tag copies nothing;
`docker push` after a `docker tag` uploads no layers. If your promotion to
production takes as long as your build, it is a build. Registry-native tools
make this explicit — `docker buildx imagetools create -t repo:production
repo:git-<sha>` and `crane tag` never pull the image at all.

**The environment goes in the config, not in the image.** The moment you build
`:production` separately you invite a `--build-arg ENV=production` into it, and
now the artefact staging tested cannot become the production one even in
principle. Same image everywhere, different configuration injected at run time.
Which is also what makes the rollback trivial: point the tag back.

**The trail matters as much as the bytes.** `build.id` here is a stand-in for
build provenance: the commit, the run, the builder, the inputs. When production
is on fire, "which build is this and what went into it" is the first question,
and an image that cannot answer it costs you the first ten minutes.

</details>
