#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Throughput and instability from the history, the survey for the rest:
# low throughput, low instability, low friction and burnout, product high.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q http://devops:devopslings@127.0.0.1:3000/devops/checkout.git "$work/r"
cd "$work/r"

prev=""
total=0
rework=0
while read -r tag at commit; do
  git cat-file tag "$tag" | grep -qx 'result: succeeded' || continue
  total=$((total + 1))
  is_rework=0
  for c in $(git rev-list "$commit" ${prev:+"^$prev"}); do
    echo "$((at - $(git log -1 --format=%ct "$c")))" >> "$work/lead"
    fixed=$(git log -1 --format=%b "$c" |
      sed -n 's/^Fixes: \([0-9a-f]*\).*/\1/p; s/^This reverts commit \([0-9a-f]*\)\..*/\1/p')
    if [ -n "$fixed" ] && [ -n "$prev" ] && git merge-base --is-ancestor "$fixed" "$prev"; then
      is_rework=1
    fi
  done
  rework=$((rework + is_rework))
  prev=$commit
done < <(git for-each-ref --sort=taggerdate \
  --format='%(refname:short) %(taggerdate:unix) %(*objectname)' refs/tags/deploy/production)

cat > "$DEVOPSLINGS_ROOT/scratch/archetypes/answer.txt" <<TXT
deploys-per-week=$(awk -v d="$total" 'BEGIN { printf "%.2f", d / 12 }')
lead-time-median-hours=$(sort -n "$work/lead" | awk '{ v[NR] = $1 } END { printf "%.1f", ((NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2) / 3600 }')
rework-rate=$(awk -v r="$rework" -v d="$total" 'BEGIN { printf "%.1f", 100 * r / d }')
archetype=Stable and methodical
TXT
