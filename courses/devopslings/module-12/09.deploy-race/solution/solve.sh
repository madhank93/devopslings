#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# One road to production. The hotfix trigger goes, so main is the only ref that
# can write the :live tag and the two deploys can no longer overlap. An urgent
# change reaches production the same way every other change does — by being
# merged, which is also the only way it survives the next deploy.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/checkout"
cd "$work/checkout"
git config user.email devops@example.invalid
git config user.name devops

cat > .forgejo/workflows/deploy.yml <<'YAML'
name: deploy

on:
  push:
    branches: [main]

env:
  IMAGE: 127.0.0.1:5000/checkout

jobs:
  deploy:
    runs-on: docker
    container:
      image: docker:27-cli
      options: -v /var/run/docker.sock:/var/run/docker.sock
    steps:
      - run: |
          git clone -q http://forge:3000/devops/checkout.git .
          git checkout -q "${{ github.sha }}"

          # Pending schema changes are applied before the new code is live.
          if [ -d migrations ]; then
            echo "applying migrations"
            sleep 15
          fi

          docker build --build-arg GIT_SHA="${{ github.sha }}" -t "${IMAGE}:live" .
          docker push "${IMAGE}:live"
          echo "live is now ${{ github.sha }}"
YAML

git add -A
git commit -qm "deploy to production from main only"
git push -q origin main
