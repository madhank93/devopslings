#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The fault is drawn at random, so this is the triage order the lesson teaches,
# asked of the repository one question at a time until one answers.
set -euo pipefail

root=$(pwd)
w=$(mktemp -d)
trap 'rm -rf "$w"' EXIT

git -c protocol.file.allow=always clone -q --recurse-submodules "$root/remotes/app.git" "$w/ci"
git -C "$w/ci" log -p --all > "$w/log"
unit() { (cd "$root/app" && sh -c ". ./lib.sh; $1" 2>&1) || true; }

cd app

# The newest position main's reflog remembers that main no longer contains.
lost_tip() {
  git log -g --format=%H main > "$w/reflog"
  while read -r c; do
    git merge-base --is-ancestor "$c" main || { echo "$c"; return; }
  done < "$w/reflog"
}

# ---- what should never have been committed ---------------------------------
tok=$(grep -oE 'pgw_live_[0-9a-f]{8,}' "$w/log" | awk 'NR==1' || true)
if [ -n "$tok" ]; then
  "$root/issuer" revoke "$tok" >/dev/null
  file=$(git log --all --format= --name-only -S "$tok" | awk 'NF && !s {print; s=1}')
  FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f \
    --index-filter "git rm -q --cached --ignore-unmatch '$file'" \
    --prune-empty -- --branches >/dev/null 2>&1
  git for-each-ref --format='%(refname)' refs/original \
    | while read -r ref; do git update-ref -d "$ref"; done
  git reflog expire --expire=now --all
  git gc -q --prune=now
  git push -q --force origin --all
  cause="secret: a live token committed in $file and deleted later, still in history"
  evidence="git log -p --all -S <token>"
  detection="secret scan in a pre-receive hook: page on > 0 matches"

# ---- is everything main had still on it? -----------------------------------
elif lost=$(lost_tip) && [ -n "$lost" ]; then
  git reset -q --hard "$lost"
  git push -q origin main
  cause="main was reset --hard and force-pushed, dropping three commits"
  evidence="git reflog"
  detection="alert on any force push to main: > 0 non-fast-forward updates"

# ---- does the parent record the submodule commit it should? ----------------
elif rec=$(git ls-tree HEAD vendor/fmt | awk '{print $3}') \
     && git -C vendor/fmt fetch -q origin main \
     && ! git -C vendor/fmt merge-base --is-ancestor FETCH_HEAD "$rec"; then
  git -C vendor/fmt checkout -q FETCH_HEAD
  git add vendor/fmt
  git commit -q -m 'vendor/fmt: back to the published separator fix'
  git push -q origin main
  cause="the vendor/fmt submodule gitlink was moved back to an older commit"
  evidence="git log -p -- vendor/fmt and git submodule status"
  detection="ci on a fresh recursive clone: fail on 1 gitlink that moves backwards"

# ---- did every merge bring its side? ---------------------------------------
elif [ "$(unit 'discount 10000 50')" != 7000 ]; then
  hot=$(git rev-parse origin/hotfix/coupon-cap)
  git cherry-pick -x "$hot" >/dev/null
  git push -q origin main
  cause="the hotfix/coupon-cap merge kept only main's side and dropped the cap"
  evidence="git show of the merge, and git diff main origin/hotfix/coupon-cap -- lib.sh"
  detection="a test for the hotfix in ci: page on 1 failing test"

# ---- where did behaviour change? -------------------------------------------
else
  first=$(git rev-list --max-parents=0 main)
  git bisect start main "$first" >/dev/null
  git bisect run sh -c '. ./lib.sh; [ "$(tax 1019)" = 82 ]' >/dev/null
  bad=$(git rev-parse refs/bisect/bad)
  git bisect reset >/dev/null 2>&1
  git revert --no-edit "$bad" >/dev/null
  git push -q origin main
  cause="regression introduced in $(git rev-parse --short=10 "$bad"): tax rounding changed"
  evidence="git bisect run"
  detection="tests in ci on every commit: page on 1 failure"
fi

cd "$root"
printf 'cause: %s\nevidence: %s\ndetection: %s\n' "$cause" "$evidence" "$detection" > triage.md
