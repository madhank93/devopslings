---
kind: lesson
title: "staging and production are running different bytes"
description: |
  The pipeline builds, deploys to staging, waits for a human, then deploys to
  production. Production is a second build of the same commit, so what was
  tested in staging is not what is running. Learn to build an artefact once and
  promote it by digest.
name: promote-do-not-rebuild
slug: promote-do-not-rebuild
createdAt: "2026-09-02"

sandbox:
  stack: ci-stack
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 900
    run: |
      reg="http://127.0.0.1:5000"
      accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

      # Start from an empty repository in the registry. A tag left behind by an
      # earlier attempt would show staging and production already in agreement,
      # which is the state the exercise is supposed to end in, not begin in.
      #
      # Every lookup here is allowed to find nothing — the registry answers 404
      # for a repository that was never pushed — so each one absorbs its own
      # failure rather than tripping `set -e`.
      tags=$(curl -fsS "${reg}/v2/checkout/tags/list" 2>/dev/null \
               | tr ',[]' '\n\n\n' | sed -n 's/.*"\([^"]*\)".*/\1/p' \
               | grep -v '^tags$\|^name$\|^checkout$' || true)
      for tag in $tags; do
        digest=$(curl -fsS -H "Accept: ${accept}" -o /dev/null -D - \
                   "${reg}/v2/checkout/manifests/${tag}" 2>/dev/null \
                   | grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}' || true)
        if [ -n "$digest" ]; then
          curl -fsS -X DELETE "${reg}/v2/checkout/manifests/${digest}" >/dev/null 2>&1 || true
        fi
      done

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT

      git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/checkout"
      cd "$work/checkout"
      git config user.email devops@example.invalid
      git config user.name devops

      rm -rf .forgejo .github src vendor node_modules package.json package-lock.json Dockerfile
      mkdir -p src .forgejo/workflows

      cat > src/server.js <<'JS'
      const http = require("node:http");

      const PRICE = 100;

      http
        .createServer((req, res) => {
          res.setHeader("content-type", "application/json");
          res.end(JSON.stringify({ price: PRICE }));
        })
        .listen(8080);
      JS

      # BUILT_AT is stamped into the image on purpose: an incident that starts
      # with "which build is this?" is answered by the label, not by guesswork.
      # It also means two builds of one commit are two different images.
      cat > Dockerfile <<'DOCKER'
      FROM node:22-bookworm-slim
      ARG BUILT_AT
      LABEL build.id="${BUILT_AT}"
      WORKDIR /app
      COPY src/ ./src/
      RUN printf '%s' "${BUILT_AT}" > /app/BUILD_ID
      CMD ["node", "src/server.js"]
      DOCKER

      # `actions/checkout` is a Node action and this job's image is docker:27-cli,
      # which has no Node — so the source arrives by git clone. The socket is the
      # host daemon's, which is why images are tagged 127.0.0.1:5000 rather than
      # by the registry's compose service name.
      cat > .forgejo/workflows/ci.yml <<'YAML'
      name: ci

      on: [push]

      env:
        IMAGE: 127.0.0.1:5000/checkout

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
                docker build --build-arg BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%S)-$$" \
                  -t "${IMAGE}:staging" .
                docker push "${IMAGE}:staging"

        deploy-staging:
          runs-on: docker
          needs: [build]
          container:
            image: docker:27-cli
            options: -v /var/run/docker.sock:/var/run/docker.sock
          steps:
            - run: |
                docker pull "${IMAGE}:staging"
                docker image inspect "${IMAGE}:staging" \
                  --format 'staging is now build {{index .Config.Labels "build.id"}}'

        deploy-production:
          runs-on: docker
          needs: [deploy-staging]
          container:
            image: docker:27-cli
            options: -v /var/run/docker.sock:/var/run/docker.sock
          steps:
            - run: |
                git clone -q http://forge:3000/devops/checkout.git .
                git checkout -q "${{ github.sha }}"
                docker build --build-arg BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%S)-$$" \
                  -t "${IMAGE}:production" .
                docker push "${IMAGE}:production"
                docker image inspect "${IMAGE}:production" \
                  --format 'production is now build {{index .Config.Labels "build.id"}}'
      YAML

      git add -A
      git commit -qm "build, deploy to staging, then deploy to production"
      git push -q origin main --force
      sha=$(git rev-parse HEAD)

      # Wait for the pipeline this push started, so the lesson opens with both
      # tags populated and the student can compare them straight away.
      api="http://127.0.0.1:3000/api/v1"
      i=0
      while [ "$i" -lt 60 ]; do
        state=$(curl -fsS -u devops:devopslings \
                  "${api}/repos/devops/checkout/actions/tasks?limit=10" 2>/dev/null \
                  | tr '{' '\n' \
                  | grep "\"head_sha\":\"${sha}\"" \
                  | grep '"name":"deploy-production"' \
                  | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p' | head -1 || true)
        case "$state" in success|failure|error) break ;; esac
        i=$((i + 1))
        sleep 5
      done

      echo "scenario ready"
      echo
      echo "  forge:     http://localhost:3000   (devops / devopslings)"
      echo "  registry:  http://localhost:5000"
      echo
      echo "The pipeline is green. Ask the registry what each environment is running:"
      echo
      echo '  for tag in staging production; do'
      echo '    curl -sI -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \'
      echo '      http://127.0.0.1:5000/v2/checkout/manifests/$tag | grep -i docker-content-digest'
      echo '  done'

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 900
    run: |
      api="http://127.0.0.1:3000/api/v1"
      reg="http://127.0.0.1:5000"
      auth="-u devops:devopslings"
      repo="devops/checkout"
      accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

      # A missing tag and an unlabelled image are both answers the checks below
      # act on, so every lookup here returns empty rather than failing — an
      # unguarded pipeline would kill the script under `set -euo pipefail` and
      # the student would see no reason at all.

      # The manifest digest a tag currently points at. Empty if the tag is absent.
      tag_digest() {
        curl -fsS -H "Accept: ${accept}" -o /dev/null -D - \
          "${reg}/v2/checkout/manifests/$1" 2>/dev/null \
          | grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}' || true
      }

      # The build.id label the image was stamped with, read out of its config
      # blob. Two images with one label value came from one `docker build`.
      tag_build_id() {
        _cfg=$(curl -fsS -H "Accept: ${accept}" "${reg}/v2/checkout/manifests/$1" 2>/dev/null \
                 | tr -d ' \n' | sed -n 's/.*"config":{[^}]*"digest":"\(sha256:[0-9a-f]*\)".*/\1/p' || true)
        [ -n "$_cfg" ] || return 0
        curl -fsS "${reg}/v2/checkout/blobs/${_cfg}" 2>/dev/null \
          | tr ',' '\n' | sed -n 's/.*"build.id":"\([^"]*\)".*/\1/p' | head -1 || true
      }

      # The final state of one job on one commit. Forgejo lists newest first, so
      # the first entry for a name is its current state.
      job_state() {
        _sha=$1
        _name=$2
        _i=0
        while [ "$_i" -lt 90 ]; do
          _s=$(curl -fsS $auth "${api}/repos/${repo}/actions/tasks?limit=20" 2>/dev/null \
                 | tr '{' '\n' \
                 | grep "\"head_sha\":\"${_sha}\"" \
                 | grep "\"name\":\"${_name}\"" \
                 | sed -n 's/.*"status":"\([a-z]*\)".*/\1/p' | head -1 || true)
          case "$_s" in success|failure|error) printf '%s' "$_s"; return 0 ;; esac
          _i=$((_i + 1))
          sleep 5
        done
        printf '%s' "$_s"
      }

      work=$(mktemp -d)
      head_sha=""
      restore() {
        if [ -n "$head_sha" ] && [ -d "$work/checkout" ]; then
          git -C "$work/checkout" push -q --force \
            "http://devops:devopslings@127.0.0.1:3000/${repo}.git" \
            "${head_sha}:main" >/dev/null 2>&1 || true
        fi
        rm -rf "$work"
      }
      trap restore EXIT

      if ! git clone -q "http://devops:devopslings@127.0.0.1:3000/${repo}.git" "$work/checkout" 2>/dev/null; then
        echo "not yet: could not clone the repository"
        exit 1
      fi
      cd "$work/checkout"
      git config user.email grader@example.invalid
      git config user.name grader
      head_sha=$(git rev-parse HEAD)

      prod=$(job_state "$head_sha" "deploy-production")
      if [ "$prod" != "success" ]; then
        echo "not yet: 'deploy-production' reports '${prod:-nothing}' on the tip of main."
        echo "Both environments still have to be deployed to; a pipeline that stops"
        echo "before production has not promoted anything."
        exit 1
      fi

      staging_1=$(tag_digest staging)
      prod_1=$(tag_digest production)

      if [ -z "$staging_1" ] || [ -z "$prod_1" ]; then
        echo "not yet: the registry has staging=${staging_1:-<missing>} and"
        echo "production=${prod_1:-<missing>}. Each environment is defined by the tag it"
        echo "runs, so both tags have to exist for there to be anything to compare."
        exit 1
      fi

      if [ "$staging_1" != "$prod_1" ]; then
        echo "not yet: staging and production point at different manifests."
        echo "  staging:    $staging_1"
        echo "  production: $prod_1"
        echo "Same commit, two images. Whatever staging proved, it proved about bytes"
        echo "that are not the ones production is serving."
        exit 1
      fi

      build_1=$(tag_build_id production)
      if [ -z "$build_1" ]; then
        echo "not yet: the deployed image carries no build.id label. The Dockerfile"
        echo "stamps it from the BUILT_AT build argument so an incident can be traced"
        echo "back to a build; removing the stamp makes the digests agree by erasing"
        echo "the evidence rather than by promoting one artefact."
        exit 1
      fi

      # Same commit agreeing with itself is not enough: a hardcoded tag would do
      # that too. Push a change and require the pipeline to carry the new one
      # through, still as a single artefact.
      sed -i.bak 's/const PRICE = 100;/const PRICE = 125;/' src/server.js
      rm -f src/server.js.bak
      if ! grep -q 'PRICE = 125' src/server.js; then
        echo "not yet: src/server.js no longer contains the PRICE constant the grader"
        echo "changes to prove a new commit reaches production. Leave it in place."
        exit 1
      fi

      git add -A
      git commit -qm "grader: change the price the service returns"
      if ! git push -q origin main 2>/dev/null; then
        echo "not yet: could not push the grader's commit"
        exit 1
      fi
      probe_sha=$(git rev-parse HEAD)

      probe_prod=$(job_state "$probe_sha" "deploy-production")
      staging_2=$(tag_digest staging)
      prod_2=$(tag_digest production)
      build_2=$(tag_build_id production)
      cd /
      restore
      trap - EXIT

      if [ "$probe_prod" != "success" ]; then
        echo "not yet: the pipeline reports '${probe_prod:-nothing}' for 'deploy-production'"
        echo "on a commit that only changes a constant in src/server.js."
        exit 1
      fi

      if [ "$staging_2" != "$prod_2" ]; then
        echo "not yet: on the grader's commit the two environments diverged again."
        echo "  staging:    $staging_2"
        echo "  production: $prod_2"
        echo "They agreed on the previous commit, so something in the pipeline still"
        echo "produces a second image rather than moving the first one forward."
        exit 1
      fi

      if [ "$prod_2" = "$prod_1" ]; then
        echo "not yet: production serves the same manifest as before the grader changed"
        echo "src/server.js. Both environments agree because they are pinned to one"
        echo "image, not because the pipeline promotes the image it just built — a new"
        echo "commit has to reach production."
        exit 1
      fi

      if [ -n "$build_2" ] && [ "$build_2" = "$build_1" ]; then
        echo "not yet: two different commits produced the same build.id."
        echo "The stamp is meant to identify one run of 'docker build'. Freezing it to a"
        echo "constant makes rebuilds byte-identical, which hides the divergence instead"
        echo "of removing it, and leaves an incident with no way to tell builds apart."
        exit 1
      fi

      echo "PASS — one image per commit, and staging and production both point at it:"
      echo "  $prod_2"
---
