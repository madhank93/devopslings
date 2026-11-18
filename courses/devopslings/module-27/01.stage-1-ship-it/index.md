---
kind: lesson
title: "Ship it: one commit, all the way to the VIP"
description: |
  A commit to checkout has to reach production on its own: built once by CI,
  pushed to the registry by digest, applied by OpenTofu from shared state,
  and served by two replicas behind the HA pair. Nothing here is new; every
  link is a check from an earlier module, and none of them may be skipped.
name: stage-1-ship-it
slug: stage-1-ship-it
createdAt: "2026-11-17"

sandbox:
  stack: ha-stack
  with: [ci-stack]
  service: host

tasks:
  init_scenario:
    init: true
    timeout_seconds: 600
    run: |
      api="http://127.0.0.1:3000/api/v1"
      reg="http://127.0.0.1:5000"
      auth="-u devops:devopslings"
      accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

      # ha-stack back to its starting topology, then nothing on the front
      # network that ha-stack did not start itself: a replica left by an
      # earlier attempt would answer at the addresses the student has to fill.
      docker exec devopslings-ha-ops ha-reset
      for c in $(docker ps -aq --filter network=devopslings-ha-stack_front); do
        case "$(docker inspect -f '{{.Name}}' "$c")" in
          /devopslings-ha-*) ;;
          *) docker rm -f "$c" >/dev/null ;;
        esac
      done

      # State from an earlier attempt would describe containers that are gone.
      docker exec devopslings-ci-stack-db-1 psql -U postgres -d app -qc \
        'drop schema if exists terraform_remote_state cascade' >/dev/null

      # Any protection rule left by a module-12 lesson would refuse the seed.
      for rule in $(curl -fsS $auth "${api}/repos/devops/checkout/branch_protections" 2>/dev/null \
                    | tr ',' '\n' | sed -n 's/.*"rule_name":"\([^"]*\)".*/\1/p' \
                    | sed 's/%/%25/g; s/ /%20/g; s/\*/%2A/g; s/?/%3F/g; s/\[/%5B/g; s/]/%5D/g; s|/|%2F|g' || true); do
        curl -fsS $auth -X DELETE "${api}/repos/devops/checkout/branch_protections/${rule}" >/dev/null 2>&1 || true
      done

      # An empty checkout repository in the registry, so every tag the checks
      # find was pushed during this attempt.
      tags=$(curl -fsS "${reg}/v2/checkout/tags/list" 2>/dev/null \
               | tr ',[]' '\n\n\n' | sed -n 's/.*"\([^"]*\)".*/\1/p' \
               | grep -v '^tags$\|^name$\|^checkout$' || true)
      for tag in $tags; do
        digest=$(curl -fsS -H "Accept: ${accept}" -o /dev/null -D - "${reg}/v2/checkout/manifests/${tag}" 2>/dev/null \
                   | grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}' || true)
        [ -z "$digest" ] || curl -fsS -X DELETE "${reg}/v2/checkout/manifests/${digest}" >/dev/null 2>&1 || true
      done

      docker exec -i devopslings-ha-ops sh -c 'cat > /ha/haproxy.cfg' <<'CFG'
      # Shared by lb1 and lb2. Production is two replicas of checkout, at the
      # addresses below; the pipeline puts them there.
      frontend www
          bind :80
          default_backend app

      backend app
          balance roundrobin
          option httpchk GET /health
          server shop1 172.29.22.31:8080 check inter 1s fall 2 rise 2
          server shop2 172.29.22.32:8080 check inter 1s fall 2 rise 2
      CFG

      work=$(mktemp -d)
      trap 'rm -rf "$work"' EXIT
      git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/checkout"
      cd "$work/checkout"
      git config user.email devops@example.invalid
      git config user.name devops
      rm -rf .forgejo .github src deploy vendor node_modules Dockerfile package.json package-lock.json
      mkdir -p src deploy .forgejo/workflows

      cat > src/server.js <<'JS'
      const http = require("node:http");
      const os = require("node:os");

      const VERSION = "1.0.0";

      http
        .createServer((req, res) => {
          res.setHeader("content-type", "application/json");
          if (req.url === "/health") {
            res.end(JSON.stringify({ ok: true }));
            return;
          }
          res.end(JSON.stringify({ version: VERSION, node: os.hostname() }));
        })
        .listen(8080);
      JS

      cat > Dockerfile <<'DOCKER'
      FROM node:22-bookworm-slim
      WORKDIR /app
      COPY src/ ./src/
      CMD ["node", "src/server.js"]
      DOCKER

      cat > deploy/main.tf <<'HCL'
      terraform {
        required_providers {
          docker = {
            source  = "kreuzwerker/docker"
            version = "4.6.0"
          }
        }

        # State lives in ci-stack's Postgres, so every pipeline run sees what
        # the last one built. `db` resolves on the CI network only.
        backend "pg" {
          conn_str = "postgres://postgres:devopslings@db:5432/app?sslmode=disable"
        }
      }

      # The host's Docker daemon, through the socket a CI job mounts.
      provider "docker" {}

      variable "image" {
        description = "What to run, as 127.0.0.1:5000/checkout@sha256:<digest>"
        type        = string
      }

      resource "docker_image" "shop" {
        name         = var.image
        keep_locally = true
      }

      # lb1 and lb2 send traffic to 172.29.22.31 and 172.29.22.32.
      resource "docker_container" "shop" {
        name  = "capstone-shop-1"
        image = docker_image.shop.image_id

        networks_advanced {
          name         = "devopslings-ha-stack_front"
          ipv4_address = "172.29.22.31"
        }

        # Marks the container as part of ha-stack, so tearing the stack down
        # removes it too instead of leaving it holding the network.
        labels {
          label = "com.docker.compose.project"
          value = "devopslings-ha-stack"
        }
      }
      HCL

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
                docker build -t "${IMAGE}:latest" .
                docker push "${IMAGE}:latest"
      YAML

      git add -A
      git commit -qm "checkout: service, image, and half a deploy"
      git push -q origin main --force

      echo "scenario ready"
      echo
      echo "  repository:  git clone http://devops:devopslings@localhost:3000/devops/checkout.git"
      echo "  pipeline:    http://localhost:3000/devops/checkout/actions"
      echo "  registry:    http://localhost:5000/v2/checkout/tags/list"
      echo "  production:  docker exec devopslings-ha-ops curl -s http://www/"
      echo
      echo "www has nothing behind it yet:"
      docker exec devopslings-ha-ops curl -s --max-time 3 http://www/ || echo "(no answer)"

  verify_done:
    needs: [init_scenario]
    timeout_seconds: 1200
    run: |
      api="http://127.0.0.1:3000/api/v1"
      reg="http://127.0.0.1:5000"
      auth="-u devops:devopslings"
      repo="devops/checkout"
      accept='application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json'

      # Every lookup below may legitimately find nothing, and each check acts
      # on that, so none of them is allowed to fail the script on its own.
      jq_ops() { docker exec -i devopslings-ha-ops jq "$@"; }
      ops() { docker exec devopslings-ha-ops "$@"; }
      sql() {
        docker exec devopslings-ci-stack-db-1 psql -U postgres -d app -tA -F' ' -c "$1" 2>/dev/null || true
      }

      tasks() { curl -fsS $auth "${api}/repos/${repo}/actions/tasks?limit=50" 2>/dev/null || true; }

      # Highest run number on a commit, 0 when it has none.
      last_run() {
        tasks | jq_ops -r --arg sha "$1" \
          '[.workflow_runs[]? | select(.head_sha == $sha) | .run_number] | max // 0' 2>/dev/null || echo 0
      }

      # "job status" lines for the newest run on $1 numbered above $2; empty
      # while there is none.
      run_jobs() {
        tasks | jq_ops -r --arg sha "$1" --argjson after "$2" '
          [.workflow_runs[]? | select(.head_sha == $sha and .run_number > $after)]
          | (map(.run_number) | max) as $n
          | .[] | select(.run_number == $n) | "\(.name) \(.status)"' 2>/dev/null || true
      }

      # Waits for that run to finish and prints its jobs. The API lists a job
      # only once a runner has picked it up, so a run counts as finished when
      # every listed job is, twice in a row 10s apart: time for a job that
      # was waiting on the others to appear. Gives up after two minutes if
      # no run appears, ten if one never finishes.
      wait_run() {
        _i=0
        _jobs=""
        _prev=""
        while [ "$_i" -lt 60 ]; do
          _jobs=$(run_jobs "$1" "$2")
          if [ -z "$_jobs" ] && [ "$_i" -ge 12 ]; then
            break
          fi
          if [ -n "$_jobs" ] && ! printf '%s\n' "$_jobs" | grep -qvE ' (success|failure|cancelled|skipped)$'; then
            [ "$_jobs" = "$_prev" ] && break
            _prev=$_jobs
          else
            _prev=""
          fi
          _i=$((_i + 1))
          sleep 10
        done
        printf '%s' "$_jobs"
      }

      # The registry tag CI pushed for a commit: the full sha, or any tag that
      # contains its first 7 characters.
      commit_tag() {
        curl -fsS "${reg}/v2/checkout/tags/list" 2>/dev/null \
          | jq_ops -r --arg full "$1" --arg short "${1:0:7}" \
              '.tags // [] | (map(select(. == $full)) + map(select(contains($short)))) | .[0] // empty' 2>/dev/null || true
      }

      tag_digest() {
        curl -fsS -H "Accept: ${accept}" -o /dev/null -D - "${reg}/v2/checkout/manifests/$1" 2>/dev/null \
          | grep -i '^docker-content-digest:' | tr -d '\r' | awk '{print $2}' || true
      }

      # The local image id for a pushed digest, pulling it if the host lacks it.
      digest_image_id() {
        docker pull -q "127.0.0.1:5000/checkout@$1" >/dev/null 2>&1 || true
        docker image inspect -f '{{.Id}}' "127.0.0.1:5000/checkout@$1" 2>/dev/null || true
      }

      # "name id" per docker_container instance in the pipeline's state.
      state_containers() {
        sql "select i->'attributes'->>'name', i->'attributes'->>'id'
               from terraform_remote_state.states s,
                    jsonb_array_elements(s.data::jsonb->'resources') r,
                    jsonb_array_elements(r->'instances') i
              where s.name = 'default' and r->>'mode' = 'managed' and r->>'type' = 'docker_container'"
      }

      # What the deploy names as its image: docker_image names, and container
      # images that are not already a resolved image id.
      state_refs() {
        sql "select coalesce(i->'attributes'->>'name', '')
               from terraform_remote_state.states s,
                    jsonb_array_elements(s.data::jsonb->'resources') r,
                    jsonb_array_elements(r->'instances') i
              where s.name = 'default' and r->>'mode' = 'managed' and r->>'type' = 'docker_image'
             union all
             select i->'attributes'->>'image'
               from terraform_remote_state.states s,
                    jsonb_array_elements(s.data::jsonb->'resources') r,
                    jsonb_array_elements(r->'instances') i
              where s.name = 'default' and r->>'mode' = 'managed' and r->>'type' = 'docker_container'
                and i->'attributes'->>'image' not like 'sha256:%'"
      }

      # A server's status on one load balancer: UP, DOWN, ... or empty.
      lb_status() {
        ops curl -fsS --max-time 2 "http://$1:8404/stats;csv" 2>/dev/null \
          | awk -F, -v s="$2" '$1 == "app" && $2 == s { print $18 }' || true
      }

      # 12 requests through www: "<version> <node>", or "ERR" for a failure.
      through_www() {
        for _ in $(seq 12); do
          ops curl -fsS --max-time 3 http://www/ 2>/dev/null \
            | jq_ops -r '"\(.version) \(.node)"' 2>/dev/null || echo ERR
        done
      }

      # The checks on whatever production is running for commit $1. Prints a
      # "not yet" and returns 1 on the first that fails.
      check_release() {
        _sha=$1
        _jobs=$(wait_run "$_sha" 0)
        if [ -z "$_jobs" ]; then
          echo "not yet: no pipeline ran for ${_sha:0:12}, the tip of main. Production is"
          echo "only ever what the pipeline put there, so the pipeline has to run on every push."
          return 1
        fi
        _bad=$(printf '%s\n' "$_jobs" | grep -v ' success$' | head -1 || true)
        if [ -n "$_bad" ]; then
          echo "not yet: job '${_bad% *}' ended '${_bad##* }' on ${_sha:0:12}, the tip of main."
          echo "Its log is under http://localhost:3000/${repo}/actions."
          return 1
        fi

        _tag=$(commit_tag "$_sha")
        if [ -z "$_tag" ]; then
          echo "not yet: no checkout image in the registry is tagged with commit ${_sha:0:12}."
          echo "The pipeline is green, but a tag like :latest is moved by every build, so it"
          echo "cannot say which build is which; push one named after the commit."
          return 1
        fi
        _want=$(digest_image_id "$(tag_digest "$_tag")")

        _rows=$(state_containers)
        if [ -z "$_rows" ]; then
          echo "not yet: the tofu state in ci-stack's Postgres manages no containers."
          echo "Whatever deployed production did not apply deploy/main.tf through that"
          echo "backend: a container started by hand, or tofu run with some other state,"
          echo "is invisible to the next pipeline run."
          return 1
        fi
        _n=$(printf '%s\n' "$_rows" | grep -c . || true)
        if [ "$_n" -lt 2 ]; then
          echo "not yet: tofu manages ${_n} container. lb1 and lb2 are a pair, but behind"
          echo "them production is still one process; when it stops, www stops."
          return 1
        fi

        _ref=$(state_refs | grep -v '@sha256:' | head -1 || true)
        if [ -n "$_ref" ]; then
          echo "not yet: the deploy names its image as '${_ref}'. A tag can be repointed"
          echo "after the plan is made; deploy the digest the build pushed, image@sha256:..."
          return 1
        fi

        while read -r _name _id; do
          _run=$(docker inspect -f '{{.State.Running}} {{.Image}}' "$_id" 2>/dev/null || true)
          if [ "${_run%% *}" != "true" ]; then
            echo "not yet: state lists ${_name}, but no such container is running. Code,"
            echo "state and the real thing disagree; the next apply would have to rebuild it."
            return 1
          fi
          if [ "${_run#* }" != "$_want" ]; then
            echo "not yet: ${_name} runs image ${_run#* }, but CI built ${_want:-nothing} for"
            echo "${_sha:0:12} (tag ${_tag}). Either the image was built or picked by hand,"
            echo "or no job in the pipeline applies deploy/main.tf, so a new commit never"
            echo "reaches production."
            return 1
          fi
        done <<EOF
      $_rows
      EOF

        for _lb in lb1 lb2; do
          for _s in shop1 shop2; do
            _st=""
            for _ in $(seq 15); do
              _st=$(lb_status "$_lb" "$_s")
              case "$_st" in UP*) break ;; esac
              sleep 1
            done
            case "$_st" in UP*) ;; *)
              echo "not yet: ${_lb} reports ${_s} as '${_st:-missing}'. It health-checks"
              echo "172.29.22.3${_s#shop}:8080/health; a replica has to be at that address."
              return 1 ;;
            esac
          done
        done
        return 0
      }

      work=$(mktemp -d)
      head_sha=""
      stopped=""
      restore() {
        [ -z "$stopped" ] || docker start "$stopped" >/dev/null 2>&1 || true
        if [ -n "$head_sha" ] && [ -d "$work/checkout" ]; then
          _before=$(last_run "$head_sha")
          if git -C "$work/checkout" push -q --force origin "${head_sha}:main" >/dev/null 2>&1; then
            # The redeploy of the student's commit has to finish here, or the
            # next check would grade production halfway back.
            wait_run "$head_sha" "$_before" >/dev/null
          fi
        fi
        rm -rf "$work"
      }
      trap restore EXIT

      if ! git clone -q "http://devops:devopslings@127.0.0.1:3000/${repo}.git" "$work/checkout" 2>/dev/null; then
        echo "not yet: could not clone ${repo}"
        exit 1
      fi
      cd "$work/checkout"
      git config user.email grader@example.invalid
      git config user.name grader
      sha=$(git rev-parse HEAD)

      check_release "$sha" || exit 1

      out=$(through_www)
      bad=$(printf '%s\n' "$out" | grep -c '^ERR$' || true)
      nodes=$(printf '%s\n' "$out" | grep -v '^ERR$' | awk '{print $2}' | sort -u | grep -c . || true)
      if [ "$bad" -gt 0 ] || [ "$nodes" -lt 2 ]; then
        echo "not yet: of 12 requests to www, ${bad} failed and ${nodes} replica(s) answered."
        echo "Both replicas are UP on both load balancers, so look at /ha/lb1/log."
        exit 1
      fi

      # Either replica can die and www keeps answering.
      first=$(state_containers | head -1 | awk '{print $2}')
      stopped=$first
      docker kill "$first" >/dev/null
      sleep 4
      out=$(through_www)
      docker start "$first" >/dev/null
      stopped=""
      bad=$(printf '%s\n' "$out" | grep -c '^ERR$' || true)
      if [ "$bad" -gt 0 ]; then
        echo "not yet: with one replica killed, ${bad} of 12 requests to www failed."
        exit 1
      fi
      for _ in $(seq 20); do
        case "$(lb_status lb1 shop1)$(lb_status lb1 shop2)" in UP*UP*) break ;; esac
        sleep 1
      done

      # The whole path, end to end, on a commit the student never saw.
      if ! grep -q 'const VERSION = "' src/server.js; then
        echo "not yet: src/server.js no longer has the VERSION constant the grader changes"
        echo "to prove a new commit reaches production. Leave it in place."
        exit 1
      fi
      probe="probe-$(date +%s)"
      sed -i.bak "s/const VERSION = \"[^\"]*\"/const VERSION = \"${probe}\"/" src/server.js
      rm -f src/server.js.bak
      git add -A
      git commit -qm "grader: release ${probe}"
      head_sha=$sha
      if ! git push -q origin HEAD:main 2>/dev/null; then
        echo "not yet: could not push the grader's commit to main"
        exit 1
      fi
      probe_sha=$(git rev-parse HEAD)

      if ! check_release "$probe_sha"; then
        echo "That was on the grader's commit ${probe_sha:0:12}, which only changes VERSION."
        echo "Your own commit passed the same checks, so something that got it to production"
        echo "does not happen for a new commit: a step done by hand, or a value pinned to it."
        exit 1
      fi
      out=$(through_www)
      if printf '%s\n' "$out" | grep -qv "^${probe} "; then
        echo "not yet: the pipeline went green on the grader's commit, but www still answers"
        echo "$(printf '%s\n' "$out" | grep -v "^${probe} " | head -1 | awk '{print $1}') instead of ${probe}."
        exit 1
      fi

      cd /
      restore
      trap - EXIT
      echo "PASS: a commit nobody touched by hand went build, registry, plan, apply, and"
      echo "out through both load balancers on two replicas, each of which can die."
---
