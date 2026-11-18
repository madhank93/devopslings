#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Walk the successful production deploys oldest first. Each one carried the
# commits between the previous deploy's commit and its own; every one of those
# commits gets a lead time, from its commit date to this deploy's tag date.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q http://devops:devopslings@127.0.0.1:3000/devops/checkout.git "$work/r"
cd "$work/r"

prev=""
git for-each-ref --sort=taggerdate \
  --format='%(refname:short) %(taggerdate:unix) %(*objectname)' refs/tags/deploy/production |
while read -r tag at commit; do
  git cat-file tag "$tag" | grep -qx 'result: succeeded' || continue
  for c in $(git rev-list "$commit" ${prev:+"^$prev"}); do
    echo "$((at - $(git log -1 --format=%ct "$c"))) $tag"
  done
  prev=$commit
done | sort -n > "$work/lead"

n=$(wc -l < "$work/lead" | tr -d ' ')
pct() { awk -v p="$1" -v n="$n" 'NR == int(p * n + 0.999999) { printf "%.2f", $1 / 3600 }' "$work/lead"; }

cat > "$DEVOPSLINGS_ROOT/scratch/lead-time/answer.txt" <<TXT
commits=$n
median-hours=$(pct 0.5)
p90-hours=$(pct 0.9)
slowest-deploy=$(tail -1 "$work/lead" | awk '{ print $2 }')
TXT
