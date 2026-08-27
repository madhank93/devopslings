#!/bin/sh
set -e

# Find the lost release commit in the reflog and point main back at it
# awk reads all of git reflog rather than grep -m1, which would exit early,
# send git reflog a SIGPIPE, and abort the script under pipefail.
lost=$(git reflog | awk '/release: ship v2.0/ && !seen {print $1; seen=1}')
git reset --hard "$lost" >/dev/null

# Write the answer file
cat > recovery.md <<ANS
recovered_version: shipped: v2.0
found_with: git reflog
ANS