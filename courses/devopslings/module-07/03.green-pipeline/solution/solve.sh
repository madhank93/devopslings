#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Three things, and the order is the lesson:
#   1. make CI actually run the suite (the script name and the workflow have to
#      agree, and --if-present has to go)
#   2. watch it go red — that red is a real bug that shipped a month ago
#   3. fix the bug
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/checkout.git" "$work/c"
cd "$work/c"
git config user.email devops@example.invalid
git config user.name devops

# 1. The script is "tests", the workflow asked for "test", and --if-present
#    turned that mismatch into a pass. Name them the same thing and drop the
#    flag: a missing test script should break the build, loudly.
cat > package.json <<'JSON'
{
  "name": "checkout",
  "version": "1.0.0",
  "scripts": {
    "test": "node --test"
  }
}
JSON

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

# 3. The bug the suite has been failing to report: the total ignores qty, so a
#    cart with three of something charges for one.
cat > src/cart.js <<'JS'
function cartTotal(items) {
  return items.reduce((sum, item) => sum + item.price * item.qty, 0);
}

module.exports = { cartTotal };
JS

git add -A
git commit -qm "run the tests in CI, and fix the total they were failing to report"
git push -q origin main
