#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The cache key has to name every input that decides what is in the cache. The
# only one here is the lockfile, and hashFiles() puts its content in the key, so
# a changed lockfile is a different key and therefore a miss.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/checkout"
cd "$work/checkout"
git config user.email devops@example.invalid
git config user.name devops

cat > .forgejo/workflows/ci.yml <<'YAML'
name: ci

on: [push]

jobs:
  test:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4

      - uses: actions/cache@v4
        id: deps
        with:
          path: node_modules
          key: node-modules-${{ runner.os }}-${{ hashFiles('package-lock.json') }}

      - run: npm ci --offline
        if: steps.deps.outputs.cache-hit != 'true'

      - run: npm test
YAML

git add -A
git commit -qm "key the dependency cache on the lockfile"
git push -q origin main
