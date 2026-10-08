---
kind: lesson
title: "staging ran an image nobody built"
description: |
  Someone pushed a build from their laptop to `shop/cart:staging`, and the
  deploy ran it, because the deploy trusts anything the registry hands it.
  Sign the release with cosign, and make the runtime's own pull policy refuse
  any image that does not carry a valid signature — including a trusted tag
  that now points somewhere else.
name: cosign-sign-and-verify
slug: cosign-sign-and-verify
createdAt: "2026-10-08"

sandbox:
  stack: registry-stack
  service: box

tasks:
  init_scenario:
    init: true
    timeout_seconds: 300
    run: |
      reset-registry
      reg=127.0.0.1:15000
      repo=$reg/shop/cart
      crane auth login "$reg" -u devops -p devopslings >/dev/null 2>&1

      rm -rf /work/keys /work/deploy
      mkdir -p /work/keys /work/deploy
      docker rm -f shop-cart >/dev/null 2>&1 || true

      work=$(mktemp -d)
      image() {
        printf '{"service":"cart","build":"%s"}\n' "$1" > "$work/build.json"
        tar -C "$work" -cf "$work/layer.tar" build.json
        crane append -f "$work/layer.tar" -t "$repo:$2" >/dev/null 2>&1
      }
      # CI's release: tagged with the commit and the version, as every build is.
      image "ci 1.2.0" git-7f3c2e1
      crane tag "$repo:git-7f3c2e1" 1.2.0 >/dev/null 2>&1
      crane tag "$repo:git-7f3c2e1" staging >/dev/null 2>&1
      # Tuesday, from a laptop.
      image "laptop, uncommitted changes" staging
      rm -rf "$work"

      # The runtime's trust policy, as found: accept anything from anywhere.
      cat > /etc/containers/policy.json <<'JSON'
      {
        "default": [{ "type": "insecureAcceptAnything" }]
      }
      JSON

      # Where to look for cosign signatures. Without this the runtime cannot see
      # a signature even when one exists.
      mkdir -p /etc/containers/registries.d
      cat > /etc/containers/registries.d/local.yaml <<'YAML'
      docker:
        127.0.0.1:15000:
          use-sigstore-attachments: true
      YAML

      cat > /work/deploy/deploy.sh <<'SH'
      #!/bin/sh
      # Pull an image through the runtime's trust policy and stage it as the
      # shop-cart container.
      # Usage: deploy.sh <image-reference>
      set -eu
      ref=${1:?usage: deploy.sh <image-reference>}
      skopeo copy --quiet --remove-signatures \
        --policy /etc/containers/policy.json \
        --src-tls-verify=false --src-creds devops:devopslings \
        "docker://$ref" docker-daemon:shop-cart:deployed
      docker rm -f shop-cart >/dev/null 2>&1 || true
      docker create --name shop-cart \
        --label com.docker.compose.project=devopslings-registry-stack \
        --label com.docker.compose.service=shop-cart \
        --label com.docker.compose.oneoff=False \
        shop-cart:deployed /cart >/dev/null
      echo "deployed $ref"
      SH
      chmod +x /work/deploy/deploy.sh

      /work/deploy/deploy.sh "$repo:staging" >/dev/null
      rm -f /root/.docker/config.json

      echo "scenario ready"
      echo
      echo "  deploy:        /work/deploy/deploy.sh <image>"
      echo "  trust policy:  /etc/containers/policy.json"
      echo "  keys go in:    /work/keys/"
      echo
      echo "Staging is running:"
      echo "  $(docker cp shop-cart:/build.json - | tar -xO)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 300
    run: |
      reg=127.0.0.1:15000
      repo=$reg/shop/cart
      export DOCKER_CONFIG=$(mktemp -d)
      work=$(mktemp -d)
      moved=""
      restore() {
        if [ -n "$moved" ]; then
          crane tag "$repo:git-7f3c2e1" 1.2.0 >/dev/null 2>&1 || true
        fi
        rm -rf "$DOCKER_CONFIG" "$work"
      }
      trap restore EXIT
      crane auth login "$reg" -u devops -p devopslings >/dev/null 2>&1

      # Exactly the pull the runtime does, into a scratch directory instead of
      # the daemon. Prints skopeo's reason on failure.
      pull() {
        rm -rf "$work/pulled"
        skopeo copy --quiet --remove-signatures \
          --policy /etc/containers/policy.json \
          --src-tls-verify=false --src-creds devops:devopslings \
          "docker://$1" "dir:$work/pulled" 2>&1
      }

      if ! jq -e . /etc/containers/policy.json >/dev/null 2>&1; then
        echo "not yet: /etc/containers/policy.json is not valid JSON."
        exit 1
      fi

      release=$(crane digest "$repo:git-7f3c2e1" 2>/dev/null || true)
      if [ -z "$release" ]; then
        echo "not yet: the release build shop/cart:git-7f3c2e1 is gone. Reset the scenario."
        exit 1
      fi

      if ! out=$(pull "$repo:1.2.0"); then
        echo "not yet: the policy refuses release 1.2.0, which is the image that should"
        echo "deploy. skopeo says:"
        echo "  $out" | tail -1
        exit 1
      fi

      # An image pushed straight to the registry, by someone with push access and
      # no signing key.
      printf '{"service":"cart","build":"grader, unsigned %s"}\n' "$$" > "$work/build.json"
      tar -C "$work" -cf "$work/layer.tar" build.json
      crane append -f "$work/layer.tar" -t "$repo:grader-unsigned" >/dev/null 2>&1
      if pull "$repo:grader-unsigned" >/dev/null; then
        echo "not yet: the grader pushed an unsigned image to shop/cart and the policy"
        echo "let it through. Anyone with push access can still put code into staging."
        exit 1
      fi

      # The same unsigned image under the release's own tag: what a compromised
      # CI token or a careless push would do.
      moved=yes
      crane tag "$repo:grader-unsigned" 1.2.0 >/dev/null 2>&1
      if pull "$repo:1.2.0" >/dev/null; then
        echo "not yet: the grader moved the 1.2.0 tag to an unsigned image and the policy"
        echo "accepted it. The trust has to follow the image's content, not its name."
        exit 1
      fi
      crane tag "$repo:git-7f3c2e1" 1.2.0 >/dev/null 2>&1
      moved=""

      if ! out=$(pull "$repo@$release"); then
        echo "not yet: the signed release, pulled by digest, was refused:"
        echo "  $out" | tail -1
        exit 1
      fi

      echo "PASS — release 1.2.0 deploys; an unsigned image, and an unsigned image"
      echo "wearing the release's tag, are both refused."
---
