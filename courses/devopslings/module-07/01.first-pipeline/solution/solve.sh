#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The workflow itself is unremarkable. The one thing that has to be right is
# `runs-on:`, which must name a label this runner actually advertises. A job
# asking for `ubuntu-latest` is asking for a GitHub-hosted runner, and there
# aren't any here, so it waits forever without ever reporting an error.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/checkout"
cd "$work/checkout"
git config user.email devops@example.invalid
git config user.name devops

mkdir -p .forgejo/workflows
cat > .forgejo/workflows/test.yml <<'YAML'
name: test

on: [push]

jobs:
  test:
    # This runner advertises `docker` and `host`. `ubuntu-latest` would sit in
    # `waiting` forever.
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
      - run: npm test
YAML

git add -A
git commit -qm "run the tests on every push"
git push -q origin main
