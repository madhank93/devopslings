#!/bin/sh
set -e

# Rewrite every commit, dropping the file that held the token. --index-filter
# edits the index directly, so it never checks a tree out — far faster than
# --tree-filter over a whole history. --prune-empty discards the commit that
# only added the file, which now changes nothing.
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f \
  --index-filter 'git rm --cached --ignore-unmatch deploy/config.yml' \
  --prune-empty -- --all >/dev/null 2>&1

# filter-branch saves the pre-rewrite tips under refs/original/ as a backup.
# They are real refs: until they are gone the old commits are still reachable
# and the secret is still in the repository.
git for-each-ref --format='%(refname)' refs/original \
  | while read -r ref; do git update-ref -d "$ref"; done

# Drop the reflog entries and collect the now-unreferenced objects, so this
# clone stops carrying the blob at all.
git reflog expire --expire=now --all
git gc --prune=now --quiet

cat > rotation.md <<ANS
purged_with: git filter-branch --index-filter
rotated: yes
why: the token was already pushed and cloned, so rewriting my history does not invalidate the credential
ANS
