#!/bin/sh
set -e

first=$(git rev-list --max-parents=0 main)
git bisect start >/dev/null 2>&1
git bisect bad main >/dev/null 2>&1
git bisect good "$first" >/dev/null 2>&1
culprit=$(git bisect run sh test.sh 2>/dev/null | sed -n 's/^\([0-9a-f]\{40\}\) is the first bad commit.*/\1/p' | head -1)
git bisect reset >/dev/null 2>&1

cat > bisect-answer.md <<ANS
first_bad_commit: $(git rev-parse --short "$culprit")
found_with: git bisect
ANS
