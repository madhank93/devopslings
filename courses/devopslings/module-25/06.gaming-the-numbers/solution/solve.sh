#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The nightly redeploy re-tags whatever production already runs: a deployment
# that carries no commit. Lead time per change is each commit to the first
# successful deploy whose commit contains it, split at the quarter boundary.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q http://devops:devopslings@127.0.0.1:3000/devops/checkout.git "$work/r"
cd "$work/r"
q4=$(date -u -d 2026-09-28 +%s 2>/dev/null || date -u -j -f %F 2026-09-28 +%s)

prev=""
noops=0
git for-each-ref --sort=taggerdate \
  --format='%(refname:short) %(taggerdate:unix) %(*objectname)' refs/tags/deploy/production > "$work/tags"
while read -r tag at commit; do
  git cat-file tag "$tag" | grep -qx 'result: succeeded' || continue
  if [ "$commit" = "$prev" ]; then
    noops=$((noops + 1))
  fi
  for c in $(git rev-list "$commit" ${prev:+"^$prev"}); do
    echo "$((at >= q4 ? 4 : 3)) $((at - $(git log -1 --format=%ct "$c")))"
  done
  prev=$commit
done < "$work/tags" > "$work/lead"

median() {
  awk -v q="$1" '$1 == q { print $2 / 3600 }' "$work/lead" | sort -n |
    awk '{ v[NR] = $1 } END { printf "%.1f", (NR % 2) ? v[(NR + 1) / 2] : (v[NR / 2] + v[NR / 2 + 1]) / 2 }'
}

cat > "$DEVOPSLINGS_ROOT/scratch/gaming-the-numbers/answer.txt" <<TXT
gamed-metric=deployment frequency, raised by a nightly redeploy of the commit already in production
noop-deploys=$noops
lead-time-q3-hours=$(median 3)
lead-time-q4-hours=$(median 4)
counter-signal=changes delivered: commits reaching production per week, and lead time per change measured to the deploy that carried each commit
TXT
