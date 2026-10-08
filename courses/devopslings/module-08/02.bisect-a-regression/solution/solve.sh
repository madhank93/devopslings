#!/bin/sh
set -e

# A commit where total.sh does not run says nothing about the regression:
# exit 125 tells bisect to skip it rather than count it as bad.
cat > bisect-test.sh <<'T'
#!/bin/sh
out=$(sh total.sh cart.txt 2>/dev/null) || exit 125
[ "$out" = "66.40" ]
T

git bisect start main "$(git rev-list --max-parents=0 main)" >/dev/null 2>&1
git bisect run sh bisect-test.sh >/dev/null 2>&1
culprit=$(git rev-parse refs/bisect/bad)
git bisect reset >/dev/null 2>&1

cat > bisect-answer.md <<ANS
first_bad_commit: $(git rev-parse --short "$culprit")
found_with: git bisect run sh bisect-test.sh
ANS
