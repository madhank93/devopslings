#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Asks the drill's questions in order — did a service fail under a run that
# said done, did last night run more than once, did every batch get settled —
# and repairs the one line the first answer points at. It never reads
# /var/lib/settle-drill: the log, the inbox and the job are enough.
set -euo pipefail
job=/usr/local/bin/settle-nightly
log=/var/log/settle/nightly.log
day=$(grep -o 'settlement-[0-9-]*\.csv' /root/questions.txt | head -1 | sed 's/settlement-//; s/\.csv//')

# Replaces exactly one occurrence of $1 with $2 in the job, or fails.
edit() {
  python3 - "$job" "$1" "$2" <<'PY'
import sys
p, old, new = sys.argv[1:]
s = open(p).read()
assert s.count(old) == 1, f"expected one occurrence of {old!r}"
open(p, "w").write(s.replace(old, new))
PY
}

# Everything the scheduler logged for last night, every attempt.
night=$(sed -n "/ run $day\$/,\$p" "$log")
runs=$(printf '%s\n' "$night" | grep -c "^--- settle-cron .* run $day\$" || true)
files=$(find "/srv/settle/inbox/$day" -name '*.csv' | wc -l)
settled=$(printf '%s\n' "$night" | sed -n 's/.*done, \([0-9]*\) batches.*/\1/p' | tail -1)

# 1. A service failed and the job still said done. settle-rates' mirror
#    warning is printed every night and is not one.
if printf '%s\n' "$night" | grep -q '^settle-accounts: ERROR'; then
  edit 'set -eu
' 'set -euo pipefail
'
  cause="no pipefail: settle-accounts failed on page 2 (503, exit 22), and the pipeline's status was sort's"
  evidence="nightly.log: the settle-accounts 503 above 'done' and exit 0; blank accounts in the report"
  detection="payout lines with a blank account > 0, or any service ERROR in a run that exited 0"

elif printf '%s\n' "$night" | grep -q '^settle-chargebacks: ERROR'; then
  edit '  local cb=$(settle-chargebacks)
' '  local cb
  cb=$(settle-chargebacks)
'
  cause="local cb=\$(settle-chargebacks) returned local's status, so set -e never saw exit 7"
  evidence="nightly.log: the settle-chargebacks error above 'done' and exit 0"
  detection="any service ERROR line in a run that exited 0: page at > 0"

# 2. Last night ran more than once. A killed first attempt left something
#    behind for the retry; a clean second run is the job not being rerunnable.
elif [ "$runs" -ge 2 ] && printf '%s\n' "$night" | grep -q 'exit 143'; then
  edit '    settle-convert "$work/rates" < "$f" > "$sum"
' '    settle-convert "$work/rates" < "$f" > "$sum.part"
    mv "$sum.part" "$sum"
'
  edit 'mkdir -p "$work" "$out"
' 'mkdir -p "$work" "$out"
trap '"'"'rm -f "$work"/*.part "$report.part"'"'"' EXIT
'
  cause="the timeout killed the first run mid-batch; its truncated amex late.sum was reused by the retry"
  evidence="exit 143 in nightly.log, then wc -l of work/$day/amex late.sum against the batch's 40 rows"
  detection="rows settled against rows in the inbox: page at a difference > 0"

elif [ "$runs" -ge 2 ]; then
  edit '[ -s "$report" ] || echo "merchant,account,payout_cents" > "$report"
while read -r m total; do
  echo "$m,${acct[$m]:-},$(( total - ${cb[$m]:-0} ))" >> "$report"
done < "$work/totals"
' '{
  echo "merchant,account,payout_cents"
  while read -r m total; do
    echo "$m,${acct[$m]:-},$(( total - ${cb[$m]:-0} ))"
  done < "$work/totals"
} > "$report.part"
mv "$report.part" "$report"
'
  cause="the job appends (>>) to the published report, so the second run last night duplicated every merchant"
  evidence="two runs for last night in nightly.log; sort | uniq -d on the report"
  detection="merchant lines in the report against merchants in the batches: page at > 0 duplicates"

# 3. Every batch in the inbox was settled.
elif [ "${settled:-0}" -lt "$files" ]; then
  edit 'for name in $(ls "$inbox"); do
  f=$inbox/$name
' 'for f in "$inbox"/*.csv; do
'
  cause="the batch loop word-split \$(ls) on the space in 'amex late.csv' and skipped it"
  evidence="ls of the inbox shows $files files; the log says done, $settled batches"
  detection="batches settled < batch files in the inbox: page at a difference > 0"

else
  echo "no question answered, and the scenario seeds a fault on every run" >&2
  exit 1
fi

# A converted batch is trusted by the next run, so last night's is rebuilt
# from the inbox rather than reused.
rm -rf "/srv/settle/work/$day"
SETTLE_DAY=$day "$job"

install -d /root/answers
printf 'cause: %s\nevidence: %s\ndetection: %s\n' "$cause" "$evidence" "$detection" > /root/answers/triage.md
