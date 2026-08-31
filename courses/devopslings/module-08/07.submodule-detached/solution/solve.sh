#!/bin/sh
set -e

cd app

# The submodule's working copy is already at the library's published tip; make
# sure of it from the library's own origin.
git -C vendor/liblog fetch -q origin main
git -C vendor/liblog checkout -q FETCH_HEAD

# git add on the submodule path records the submodule's current commit in the parent, not its files
git add vendor/liblog
git commit -q -m 'vendor/liblog: record the commit that logs the level'

git push -q origin main
