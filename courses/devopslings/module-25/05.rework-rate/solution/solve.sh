#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A deployment is rework when a commit it carried for the first time fixes or
# reverts a commit that was already in production — the Fixes: trailer or the
# revert line names it, and merge-base --is-ancestor against the previous
# deploy says whether it had shipped.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q http://devops:devopslings@127.0.0.1:3000/devops/checkout.git "$work/r"
cd "$work/r"

prev=""
total=0
rework=()
while read -r tag commit; do
  git cat-file tag "$tag" | grep -qx 'result: succeeded' || continue
  total=$((total + 1))
  for c in $(git rev-list "$commit" ${prev:+"^$prev"}); do
    fixed=$(git log -1 --format=%b "$c" |
      sed -n 's/^Fixes: \([0-9a-f]*\).*/\1/p; s/^This reverts commit \([0-9a-f]*\)\..*/\1/p')
    if [ -n "$fixed" ] && [ -n "$prev" ] && git merge-base --is-ancestor "$fixed" "$prev"; then
      rework+=("$tag")
      break
    fi
  done
  prev=$commit
done < <(git for-each-ref --sort=taggerdate --format='%(refname:short) %(*objectname)' refs/tags/deploy/production)

cat > "$DEVOPSLINGS_ROOT/scratch/rework-rate/answer.txt" <<TXT
rework-deploys=$(IFS=,; echo "${rework[*]}")
rework-rate=$(awk -v n="${#rework[@]}" -v d="$total" 'BEGIN { printf "%.1f", 100 * n / d }')
TXT
