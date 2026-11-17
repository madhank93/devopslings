#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A deployment is a deploy/production tag whose result line says it succeeded.
# Staging tags, aborted production attempts and v1.N.0 release builds are in
# the same repository and are not changes reaching production.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q http://devops:devopslings@127.0.0.1:3000/devops/checkout.git "$work/r"
cd "$work/r"

n=0
for t in $(git tag -l 'deploy/production/*'); do
  if git cat-file tag "$t" | grep -qx 'result: succeeded'; then
    n=$((n + 1))
  fi
done

cat > "$DEVOPSLINGS_ROOT/scratch/count-your-deploys/answer.txt" <<TXT
deployments=$n
counted=each deploy/production tag whose result is succeeded, including hotfixes and the retries of aborted attempts
excluded=deploy/staging tags (not production); deploy/production tags whose result is aborted (production unchanged); v1.N.0 release tags (a build, not a deploy); commits (a deploy carries several, and some are not deployed yet)
TXT
