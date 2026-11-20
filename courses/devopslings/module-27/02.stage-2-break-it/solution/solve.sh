#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Finds the fault the way a student would, from what production and the
# repository show, and never reads the scenario's state file:
#   a second workspace in the state table        split
#   a Docker cache mount in the Dockerfile       cache
#   a retention workflow                         retention
#   a container in the state that is not there   drift
#   otherwise                                    the health check
# Each fix goes through a commit; the pipeline does the rest.
set -euo pipefail
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/files/lib.sh"
. "$DEVOPSLINGS_ROOT/courses/devopslings/module-27/02.stage-2-break-it/files/common.sh"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q "$repo_url" "$work/checkout"
cd "$work/checkout"
git config user.email devops@example.invalid
git config user.name devops

missing=""
while read -r _ id; do
  [ -z "$id" ] || [ "$(docker inspect -f '{{.State.Running}}' "$id" 2>/dev/null || true)" = true ] || missing=1
done <<EOF
$(state_containers)
EOF

if [ -n "$(sql "select name from terraform_remote_state.states where name <> 'default'")" ]; then
  # One state again, without an outage: the default workspace forgets any
  # containers that are gone and adopts the hotfix's; the hotfix workspace
  # forgets them too and is deleted. The flag moves into the code, and the
  # next apply replaces the replicas with it set.
  ids=$(docker inspect -f '{{.Id}}' capstone-shop-1 capstone-shop-2 | tr '\n' ' ')
  image=$(sql "select i->'attributes'->>'name'
                 from terraform_remote_state.states s,
                      jsonb_array_elements(s.data::jsonb->'resources') r,
                      jsonb_array_elements(r->'instances') i
                where s.name = 'default' and r->>'type' = 'docker_image'" | head -1)
  docker run --rm -i --network devopslings-ci-net -v /var/run/docker.sock:/var/run/docker.sock \
    devopslings-ha-stack-ops bash -se <<EOF
git clone -q http://forge:3000/devops/checkout.git /w && cd /w/deploy
tofu init -input=false >/dev/null
tofu workspace select hotfix >/dev/null
tofu state rm docker_container.shop docker_image.shop >/dev/null
tofu workspace select default >/dev/null
# A deploy that ran since may already have dropped them on refresh.
tofu state rm docker_container.shop >/dev/null 2>&1 || true
set -- $ids
tofu import -input=false -var 'image=${image}' 'docker_container.shop[0]' "\$1" >/dev/null
tofu import -input=false -var 'image=${image}' 'docker_container.shop[1]' "\$2" >/dev/null
tofu workspace delete hotfix >/dev/null
EOF
  perl -0pi -e 's/(  image = docker_image\.shop\.image_id\n)/$1  env   = ["PAYMENTS=disabled"]\n/' deploy/main.tf
  grep -q 'PAYMENTS=disabled' deploy/main.tf
  git add -A
  git commit -qm "deploy: payments stay disabled, in the code this time"

elif grep -q -- '--mount=type=cache' Dockerfile; then
  # The cache keeps its contents under a key made from the source, so a
  # changed source is a miss and an unchanged one still a hit.
  cat > Dockerfile <<'DOCKER'
FROM node:22-bookworm-slim
WORKDIR /app
COPY src/ ./src/
# Checking and bundling the source was most of the build time, so the bundle
# is kept in a build cache between builds, under the source's own hash.
RUN --mount=type=cache,target=/var/cache/bundle \
    key=$(cat src/*.js | sha256sum | cut -c1-16) \
 && if [ ! -f "/var/cache/bundle/${key}.js" ]; then \
      node --check src/server.js && cp src/server.js "/var/cache/bundle/${key}.js"; \
    fi \
 && cp "/var/cache/bundle/${key}.js" /app/server.js
CMD ["node", "/app/server.js"]
DOCKER
  git add -A
  git commit -qm "build: key the bundle cache on the source"

elif [ -f .forgejo/workflows/retention.yml ]; then
  # Keep the last five releases on main: the rollback window. Anything not
  # on main, and anything older, still goes.
  sed -i.bak 's/^  KEEP: 1$/  KEEP: 5/' .forgejo/workflows/retention.yml
  rm -f .forgejo/workflows/retention.yml.bak
  grep -q '^  KEEP: 5$' .forgejo/workflows/retention.yml
  git add -A
  git commit -qm "retention: keep the last five releases, the rollback window"

elif [ -n "$missing" ]; then
  # The pipeline's next apply recreates what is missing; the drift check plans
  # what that apply would do, on a schedule, and never applies.
  mkdir -p ci
  cat > ci/drift-check.sh <<'SH'
#!/bin/sh
# Exit 0: production is what deploying main's tip would leave. 2: it drifted.
# Anything else: the check could not look. It plans; it never applies.
cd "$(dirname "$0")/.." || exit 1
digest=$(curl -fsSI \
  -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  "http://registry:5000/v2/checkout/manifests/$(git rev-parse HEAD)" \
  | tr -d '\r' | awk 'tolower($1) == "docker-content-digest:" { print $2 }')
[ -n "$digest" ] || exit 1
cd deploy || exit 1
tofu init -input=false >/dev/null || exit 1
exec tofu plan -input=false -lock=false -detailed-exitcode \
  -var "image=127.0.0.1:5000/checkout@${digest}"
SH
  chmod +x ci/drift-check.sh
  cat > .forgejo/workflows/drift.yml <<'YAML'
name: drift

on:
  schedule:
    - cron: "*/30 * * * *"

jobs:
  drift:
    runs-on: docker
    container:
      image: devopslings-ha-stack-ops
      options: -v /var/run/docker.sock:/var/run/docker.sock
    steps:
      - run: |
          git clone -q http://forge:3000/devops/checkout.git .
          sh ci/drift-check.sh
YAML
  git add -A
  git commit -qm "redeploy, and check for drift every half hour"

else
  # /health asks the question every order asks: can this replica get a price?
  perl -0pi -e 's/res\.end\(JSON\.stringify\(\{ ok: true \}\)\);\n      return;/price((err) => {\n        res.statusCode = err ? 503 : 200;\n        res.end(JSON.stringify({ ok: !err }));\n      });\n      return;/' src/server.js
  grep -q 'ok: !err' src/server.js
  git add -A
  git commit -qm "health: a replica that cannot price an order is not healthy"
fi

git push -q origin HEAD:main
