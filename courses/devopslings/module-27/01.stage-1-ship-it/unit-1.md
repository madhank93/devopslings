---
title: "Ship it: one commit, all the way to the VIP"
---

## The situation

Two sandboxes are up at once. `ci-stack` has the forge, the runner and the
registry from modules 11 and 12. `ha-stack` has the pair from module 22: lb1
and lb2 running HAProxy, keepalived holding `www` on whichever of them is
alive. The load balancers already send traffic to `172.29.22.31` and
`172.29.22.32`. Nothing is there yet:

```console
$ docker exec devopslings-ha-ops curl -s http://www/
<html><body><h1>503 Service Unavailable</h1>
```

`devops/checkout` holds the service, its `Dockerfile`, and half a deploy:

- `.forgejo/workflows/ci.yml` builds the image and pushes it as `:latest`.
  That is all it does.
- `deploy/main.tf` describes one container at `172.29.22.31`, run by the host's
  Docker daemon, with its state in ci-stack's Postgres (`backend "pg"`). It
  takes the image as a variable. Nothing has ever applied it.

## Your objectives

Make a push to `main` reach `www` with nobody touching anything by hand:

1. The build runs once per commit and pushes an image tagged with that
   commit's sha.
2. A job after it resolves that tag to its digest, then plans and applies
   `deploy/main.tf` with `image=127.0.0.1:5000/checkout@sha256:...`.
3. Production is two replicas, one at each address the load balancers check.

Every piece of this is something an earlier module taught. Doing them in the
right order, in one pipeline, is the exercise.

## What you're being graded on

On the tip of `main`: every job of its newest pipeline run succeeded; the
registry has a tag naming the commit; the tofu state in ci-stack's Postgres
manages at least two containers, names the image by digest, and those
containers are running exactly the image CI built for the commit; lb1 and lb2
both report `shop1` and `shop2` UP; `www` answers from both replicas, and
keeps answering when the grader kills one.

Then the grader commits a new `VERSION` in `src/server.js`, pushes it, and runs
every one of those checks again on that commit, plus `www` answering with the
new version. Afterwards it force-pushes your commit back and waits for the
pipeline to redeploy it.

<details>
<summary>Hint 1 — where the deploy job runs</summary>

A job runs in a container on `devopslings-ci-net`, the same network as the
forge (`forge:3000`), the registry (`registry:5000`) and the state database
(`db:5432`). It needs `tofu` and the docker provider without a network
download. `ha-stack`'s ops image has both, and git and curl, and the runner
uses a local image without pulling it:

```yaml
container:
  image: devopslings-ha-stack-ops
  options: -v /var/run/docker.sock:/var/run/docker.sock
```

The socket is the host daemon's. That is what tofu's docker provider talks to,
and why the image it runs is `127.0.0.1:5000/...`: the host's view of the
registry, not the job's.

</details>

<details>
<summary>Hint 2 — from a tag to a digest</summary>

The registry answers a `HEAD` on a manifest with the digest in a header
(module 11):

```sh
curl -fsSI \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  "http://registry:5000/v2/checkout/manifests/${{ github.sha }}" \
  | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }'
```

Deploying `:latest`, or even `:<sha>`, hands tofu a name. If the name is the
same as last time, the plan is empty and production does not move; if someone
repoints it between plan and apply, production runs something nobody planned.

</details>

<details>
<summary>Hint 3 — two replicas</summary>

`count` (module 13) on `docker_container`, with the index in the name and in
the last octet of the address. Both replicas share one `docker_image`.

</details>

<details>
<summary>Solution</summary>

The workflow:

```yaml
jobs:
  build:
    runs-on: docker
    container:
      image: docker:27-cli
      options: -v /var/run/docker.sock:/var/run/docker.sock
    steps:
      - run: |
          git clone -q http://forge:3000/devops/checkout.git .
          git checkout -q "${{ github.sha }}"
          docker build -t "${IMAGE}:${{ github.sha }}" .
          docker push "${IMAGE}:${{ github.sha }}"

  deploy:
    runs-on: docker
    needs: [build]
    container:
      image: devopslings-ha-stack-ops
      options: -v /var/run/docker.sock:/var/run/docker.sock
    steps:
      - run: |
          git clone -q http://forge:3000/devops/checkout.git .
          git checkout -q "${{ github.sha }}"
          digest=$(curl -fsSI \
            -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
            "http://registry:5000/v2/checkout/manifests/${{ github.sha }}" \
            | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }')
          test -n "$digest"
          cd deploy
          tofu init -input=false
          tofu plan -input=false -out=tfplan -var "image=${IMAGE}@${digest}"
          tofu apply -input=false tfplan
```

And in `deploy/main.tf`:

```hcl
resource "docker_container" "shop" {
  count = 2
  name  = "capstone-shop-${count.index + 1}"
  image = docker_image.shop.image_id

  networks_advanced {
    name         = "devopslings-ha-stack_front"
    ipv4_address = "172.29.22.3${count.index + 1}"
  }
  # labels unchanged
}
```

### The part worth remembering

**Each link only proves something if the one before it is honest.** A green
pipeline that pushed `:latest`, a plan applied from a laptop's state file, two
load balancers in front of one process: each looks finished from where its
owner stands. The thing to check is the end-to-end path on a commit you did not
prepare, which is what the grader does.

**The plan is the review.** `tofu plan -out` followed by `tofu apply tfplan`
applies exactly what was planned. Planning by digest means the plan names the
bytes, so what was reviewed is what runs.

**State is shared or it is wrong.** The pipeline can only replace yesterday's
containers because it reads the state yesterday's run wrote. A deploy from
anywhere else, with any other state, creates things the pipeline does not know
exist.

</details>
