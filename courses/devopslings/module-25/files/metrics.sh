#!/bin/sh
# The reference measurements for module 25, computed from devops/checkout's
# commits and deploy tags. The graders run this and compare; the definitions
# here are the ones the lessons teach.
#
#   metrics.sh <repo-url> deploys     tag epoch target trigger, one per production
#                                     deploy that succeeded, oldest first
#   metrics.sh <repo-url> leadtimes   sha seconds tag, one per commit that reached
#                                     production, timed to the first deploy carrying it
#   metrics.sh <repo-url> rework      tags of deploys that shipped a fix for a change
#                                     already in production
#   metrics.sh <repo-url> noops       tags of deploys that changed nothing
#   metrics.sh <repo-url> leadstats   n, mean, p50 and p90 of the lead times in hours
#                                     (nearest-rank and interpolated), and the median
#                                     of the wrong measure: each deploy's newest commit
#   metrics.sh <repo-url> recovery <csv>   id minutes, per incident in the CSV text,
#                                     from the last production deploy before it was
#                                     detected to its resolution
#
# Runs under busybox sh, inside the ci-stack sops container. Fed on stdin
# (`sh -s -- <args>`), so nothing in it may read stdin.
set -eu

url=$1
what=$2

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q "$url" "$work/r"
cd "$work/r"

deploys() {
  git for-each-ref --sort=taggerdate \
    --format='%(refname:short) %(taggerdate:unix) %(*objectname)' refs/tags/deploy/production |
  while read -r tag epoch target; do
    body=$(git cat-file tag "$tag")
    case "$body" in
      *"
result: succeeded"*) ;;
      *) continue ;;
    esac
    trigger=$(printf '%s\n' "$body" | sed -n 's/^trigger: //p')
    echo "$tag $epoch $target $trigger"
  done
}

# Each deploy with the commits it was first to carry into production.
# <tag> <epoch> <target> <commit>..., where an empty list means nothing new.
shipped() {
  seen=""
  deploys | while read -r tag epoch target _; do
    # shellcheck disable=SC2086
    new=$(git rev-list "$target" ${seen:+--not $seen} | tr '\n' ' ')
    echo "$tag $epoch $target $new"
    seen="$seen $target"
  done
}

case "$what" in
  deploys) deploys ;;
  leadtimes)
    shipped | while read -r tag epoch _ commits; do
      for c in $commits; do
        echo "$c $((epoch - $(git log -1 --format=%ct "$c"))) $tag"
      done
    done ;;
  noops)
    shipped | while read -r tag _ _ commits; do
      [ -z "$commits" ] && echo "$tag"
    done ;;
  rework)
    prev=""
    shipped | while read -r tag _ target commits; do
      for c in $commits; do
        for t in $(git log -1 --format=%b "$c" |
                   sed -n 's/^Fixes: \([0-9a-f]\{7,\}\).*/\1/p; s/^This reverts commit \([0-9a-f]\{7,\}\)\..*/\1/p'); do
          if [ -n "$prev" ] && git merge-base --is-ancestor "$t" "$prev" 2>/dev/null; then
            echo "$tag"
            break 2
          fi
        done
      done
      prev=$target
    done ;;
  leadstats)
    shipped > "$work/shipped"
    while read -r tag epoch _ commits; do
      for c in $commits; do
        echo $((epoch - $(git log -1 --format=%ct "$c")))
      done
    done < "$work/shipped" | sort -n > "$work/all"
    while read -r tag epoch target commits; do
      [ -n "$commits" ] && echo $((epoch - $(git log -1 --format=%ct "$target")))
    done < "$work/shipped" | sort -n > "$work/head"
    awk '
      FNR == 1 { f++ }
      f == 1 { v[++n] = $1; sum += $1 }
      f == 2 { h[++m] = $1 }
      function rank(a, k, p,   r) { r = int(p * k); if (r < p * k) r++; if (r < 1) r = 1; return a[r] }
      function interp(a, k, p,   x, lo) { x = (k - 1) * p + 1; lo = int(x); return a[lo] + (x - lo) * (a[lo + 1] - a[lo]) }
      END {
        printf "n %d\nmean %.2f\n", n, sum / n / 3600
        printf "p50 %.2f %.2f\n", rank(v, n, 0.5) / 3600, interp(v, n, 0.5) / 3600
        printf "p90 %.2f %.2f\n", rank(v, n, 0.9) / 3600, interp(v, n, 0.9) / 3600
        printf "head-p50 %.2f %.2f\nheads %d\n", rank(h, m, 0.5) / 3600, interp(h, m, 0.5) / 3600, m
      }' "$work/all" "$work/head" ;;
  recovery)
    deploys > "$work/deploys"
    printf '%s\n' "$3" | tail -n +2 | while IFS=, read -r id detected resolved _; do
      [ -n "$id" ] || continue
      d=$(date -u -d "$(echo "$detected" | sed 's/T/ /; s/Z$//')" +%s)
      r=$(date -u -d "$(echo "$resolved" | sed 's/T/ /; s/Z$//')" +%s)
      dep=$(awk -v d="$d" '$2 <= d { e = $2 } END { print e }' "$work/deploys")
      echo "$id $(( (r - dep) / 60 ))"
    done ;;
  *) echo "unknown measurement: $what" >&2; exit 2 ;;
esac
