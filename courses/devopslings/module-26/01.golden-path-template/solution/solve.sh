#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The template stops being a copy of orders: every place the name lives says
# ${REPO_NAME}, and .forgejo/template tells Forgejo which files to expand.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q "http://devops:devopslings@127.0.0.1:3000/devops/service-template.git" "$work/t"
cd "$work/t"
git config user.email devops@example.invalid
git config user.name devops

sed -i.bak 's/orders/${REPO_NAME}/g' package.json observability/dashboard.json observability/alerts.yml
rm -f package.json.bak observability/*.bak

cat > README.md <<'MD'
# ${REPO_NAME}

Generated from devops/service-template. The pipeline, the dashboard
(`observability/dashboard.json`) and the alert (`observability/alerts.yml`)
are already this service's: push, and it is green.
MD

cat > .forgejo/template <<'TXT'
package.json
README.md
observability/*
TXT

git add -A
git commit -qm "template: generate the service's own name"
git push -q origin HEAD:main
