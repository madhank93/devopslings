#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# N is 3, so R + W > 3 is what makes every read set overlap every write set,
# and W = R = 2 is the only pair that satisfies it while still leaving the
# store able to answer with one of the three nodes gone.
set -euo pipefail

sed -i 's/^W=1 /W=2 /; s/^R=1 /R=2 /' /work/app/client.sh
grep -E '^[WR]=' /work/app/client.sh

install -d /work/answers
cat > /work/answers/quorum.md <<'MD'
# The profile store

# The three numbers the client is configured with, after your fix.
replication-factor-n: 3
write-quorum-w: 2
read-quorum-r: 2

# One line: why does R + W > N make a read see the write that preceded
# it? Say what the two sets of nodes have to have in common.
why-the-inequality: two subsets of three nodes whose sizes add up to more than three cannot be disjoint, so the read set always overlaps the write set in at least one node, and that node holds the newest version for the read to pick

# One line: with one of the three nodes down, what is the largest W you
# can still acknowledge a write with, and what does that leave for R?
with-one-node-down: W can be at most 2, because only 2 nodes can acknowledge anything, and R must then also be 2 so that R + W = 4 is still greater than N = 3
MD

echo "client set to W=2, R=2"
