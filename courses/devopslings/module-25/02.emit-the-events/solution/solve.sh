#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# One annotated tag per deployment, named by the run, created only when the
# deploy step succeeded. The tag's own date is the deploy time; the commit it
# points at is what was deployed.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q http://devops:devopslings@127.0.0.1:3000/devops/checkout.git "$work/c"
cd "$work/c"
git config user.email devops@example.invalid
git config user.name devops

cat > .forgejo/workflows/deploy.yml <<'YAML'
name: deploy

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
      - run: sh deploy.sh
      - name: record the deployment
        run: |
          tag="deploy/production/${{ github.run_number }}"
          git -c user.name=pipeline -c user.email=pipeline@example.invalid \
            tag -a "$tag" -m "deploy checkout to production" \
            -m "commit: ${{ github.sha }}"
          git push origin "$tag"
YAML

git add -A
git commit -qm "record one event per deployment, and only for deployments that happened"
git push -q origin main
