#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Two independent changes. The gate has to read the result of what it waited
# for, because `needs:` only orders jobs. And the flaky shard has to be retried
# in the job that runs it, so that flakiness costs seconds rather than a red
# main — three attempts still fail on a test that is genuinely broken.
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
    strategy:
      fail-fast: false
      matrix:
        shard: [unit, contract, integration]
    steps:
      - uses: actions/checkout@v4
      - run: |
          for attempt in 1 2 3; do
            if node --test src/${{ matrix.shard }}.test.js; then
              exit 0
            fi
            echo "attempt ${attempt} failed"
          done
          exit 1

  gate:
    runs-on: docker
    needs: [test]
    if: always()
    steps:
      - run: |
          echo "test result: ${{ needs.test.result }}"
          test "${{ needs.test.result }}" = "success"
YAML

git add -A
git commit -qm "make the gate read the matrix result, and retry the flaky shard"
git push -q origin main
