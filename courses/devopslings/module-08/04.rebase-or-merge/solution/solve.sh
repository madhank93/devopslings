#!/bin/sh
set -e

git checkout -q tiered-pricing
git rebase main || true

cat > pricing.sh <<'P'
#!/bin/sh
# discount_amount <subtotal> <percent>
discount_amount() {
  sub=$1
  pct=$2
  if [ "$sub" -ge 10000 ]; then
    pct=$(( pct + 10 ))
  fi
  # The bonus is added to the percentage before the cap applies, so the cap is
  # the last word: 85 becomes 95 and then 90, not 90 and then 100.
  if [ "$pct" -gt 90 ]; then
    pct=90
  fi
  echo $(( sub * pct / 100 ))
}

total() {
  echo $(( $1 - $(discount_amount "$1" "$2") ))
}
P

cat > tests.sh <<'T'
#!/bin/sh
. ./pricing.sh
fail=0
check() { [ "$2" = "$3" ] || { echo "FAIL $1: got $2 want $3"; fail=1; }; }

check plain "$(total 200 10)" 180
check clamp "$(total 200 150)" 20
check gold_tier "$(total 10000 20)" 7000
exit $fail
T

git add pricing.sh tests.sh
git -c core.editor=true rebase --continue

git checkout -q main
git merge --ff-only tiered-pricing

cat > resolution.md <<'R'
integrated_with: rebase
ours_during_conflict: main
why: taking one side wholesale drops the other side's fix and the test that covered it
R
