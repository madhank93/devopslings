#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two edits: `on: [push]` so every push is a run, and dropping `|| true` so the
# job's status is the test command's exit status rather than the shell's opinion
# of it.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/checkout"
cd "$work/checkout"
git config user.email devops@example.invalid
git config user.name devops

mkdir -p .forgejo/workflows
cat > .forgejo/workflows/ci.yml <<'YAML'
name: ci

on: [push]

jobs:
  test:
    runs-on: docker
    steps:
      - uses: actions/checkout@v4
      - run: npm test
YAML

git add -A
git commit -qm "run the tests on every push, and let them fail"
git push -q origin main
