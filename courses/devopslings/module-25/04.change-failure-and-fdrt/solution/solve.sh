#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# INC-102 (a power cut) and INC-104 (the payment provider) were not caused by a
# change. The other four were: each was resolved by deploying a revert or a fix.
# Recovery runs from the failed deployment's tag date to resolved_at.
set -euo pipefail

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dir="$DEVOPSLINGS_ROOT/scratch/change-failure-and-fdrt"
git clone -q http://devops:devopslings@127.0.0.1:3000/devops/checkout.git "$work/r"
cd "$work/r"

deploys=0
for t in $(git tag -l 'deploy/production/*'); do
  git cat-file tag "$t" | grep -qx 'result: succeeded' && deploys=$((deploys + 1))
done

# id, deploy date and resolution, both as YYYY-MM-DDTHH:MM in UTC.
for id in INC-101 INC-103 INC-105 INC-106; do
  row=$(grep "^$id," "$dir/incidents.csv")
  tag=$(echo "$row" | cut -d, -f5)
  deployed=$(TZ=UTC git for-each-ref --format='%(taggerdate:format-local:%Y-%m-%dT%H:%M)' "refs/tags/$tag")
  echo "$deployed $(echo "$row" | cut -d, -f3)"
done | awk '
  # Minutes since 1970 for YYYY-MM-DDTHH:MM, from the days-from-civil algorithm.
  function minutes(s,   y, m, d, era, yoe, doy, doe) {
    y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
    if (m <= 2) y--
    era = int(y / 400); yoe = y - era * 400
    doy = int((153 * (m + (m > 2 ? -3 : 9)) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return ((era * 146097 + doe - 719468) * 24 + substr(s, 12, 2)) * 60 + substr(s, 15, 2)
  }
  { v[++n] = minutes($2) - minutes($1) }
  END {
    for (i = 1; i <= n; i++) for (j = i + 1; j <= n; j++) if (v[j] < v[i]) { t = v[i]; v[i] = v[j]; v[j] = t }
    print (v[2] + v[3]) / 2
  }' > "$work/median"

cat > "$dir/answer.txt" <<TXT
excluded=INC-102,INC-104
change-failure-rate=$(awk -v d="$deploys" 'BEGIN { printf "%.1f", 400 / d }')
recovery-median-minutes=$(cat "$work/median")
TXT
