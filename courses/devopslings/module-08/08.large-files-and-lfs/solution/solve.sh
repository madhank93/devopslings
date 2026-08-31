#!/bin/sh
set -e

cd app

# Filters for this repository only: nothing outside the exercise is touched.
git lfs install --local

# The rewrite is what shrinks the clone — tracking a path only changes future
# commits. migrate import writes .gitattributes itself, and has to run before
# the path is tracked by hand: a tracked file that is not yet a pointer reads as
# a dirty working copy, and migrate refuses to run on one.
git lfs migrate import --everything --include="assets/*.bin" --yes

# Every commit has a new id after the rewrite, so the branch cannot
# fast-forward. The push also carries the LFS objects to the remote's store.
git push --force origin main
