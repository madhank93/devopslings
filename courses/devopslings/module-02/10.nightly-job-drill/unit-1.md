---
title: "the nightly settlement said done, and finance cannot pay from it"
---

## The situation

```
$ tail -2 /var/log/settle/nightly.log
settle: 2026-… done, … batches, … merchants
--- settle-cron exit 0
```

Last night's settlement report, `/srv/settle/out/settlement-<day>.csv`, is
wrong, and finance cannot pay from it. The job said `done` and exited 0. That is
the entire ticket, and it will be the entire ticket every time you run this
lesson — because the fault is drawn at random from five, and each is a different
way a script that works lies about having worked.

`/usr/local/bin/settle-nightly` reads one night's card batches from
`/srv/settle/inbox/<day>/*.csv`, converts each to euros with `settle-convert`
(slow: one FX lookup per transaction, so a converted batch is kept in
`work/<day>/` and reused), looks up each merchant's payout account with
`settle-accounts` and today's disputes with `settle-chargebacks`, and publishes
one payout line per merchant. Finance pays from the out file the moment it
appears. The scheduler runs the job again after a failure or a timeout, and logs
every attempt between `--- settle-cron` lines.

It worked on every night before this one. `/root/questions.txt` has the date.

You cannot memorise the answer. You can memorise the order of the questions.

## Your objectives

- Repair `settle-nightly`, so that on any night it either publishes a correct
  report and exits 0, or exits non-zero and publishes nothing
- Make last night's report right
- Write `/root/answers/triage.md`, three lines:

  ```
  cause:     <what was wrong, in a few words>
  evidence:  <the command or number that proved it>
  detection: <a signal and a threshold that would have paged first>
  ```

## What you're being graded on

First, last night's report must match what last night's batches and services
add up to. Then the grader runs the job on nights of its own, under its own
`SETTLE_ROOT` and `SETTLE_DAY`, and checks each one:

- **a healthy night** settles correctly — and its output still carries
  settle-rates' `ERROR rates-mirror … falling back to primary` line. Silencing a
  service's stderr hides its next real error with it.
- **a healthy night with `amex late.csv` in the inbox** settles all three batches.
- **a night `settle-accounts` fails on page 2**, and **a night
  `settle-chargebacks` fails outright**, both end in a non-zero exit and no
  report. A report that exists is a report finance pays from.
- **a night whose first run is killed mid-batch** by `TERM`, the way the
  scheduler's timeout kills it, settles correctly on the retry.
- **a night run twice** has the right report after the second run.
- **the four `settle-*` services are unchanged.** They stand in for other teams'
  APIs.

Every check runs every time, so a repair that fixes the seeded fault and breaks
another night fails. And `triage.md`: `cause` must describe the fault that was
seeded; `evidence` must be the command or number that proves it; `detection`
must name a signal that fits it *and* a number.

<details>
<summary>Hint 1 — the questions, in order</summary>

```
$ day=$(date -d yesterday +%F)
$ sed -n "/ run $day\$/,\$p" /var/log/settle/nightly.log   # every attempt last night
$ ls -l "/srv/settle/inbox/$day"                           # how many batches were there?
$ ls -l "/srv/settle/work/$day"; wc -l /srv/settle/work/$day/*.sum
$ sort /srv/settle/out/settlement-$day.csv | uniq -d       # anything in it twice?
$ grep -c ',,' /srv/settle/out/settlement-$day.csv          # payouts with no account
```

1. Did any service fail under a run that still said `done`?
2. Did last night run more than once, and how did each attempt end?
3. Does the number of batches the job settled match the number in the inbox?

The log answers most of it. The `rates-mirror` line is in every night's log,
including the good ones.

</details>

<details>
<summary>Hint 2 — reproduce it somewhere that is not production</summary>

The job honours `SETTLE_ROOT` and `SETTLE_DAY`, so it can be run against a
copy without touching the real report:

```
$ mkdir -p /root/t/inbox && cp -a /srv/settle/upstream /root/t/
$ cp -a "/srv/settle/inbox/$day" /root/t/inbox/
$ SETTLE_ROOT=/root/t SETTLE_DAY=$day bash -x /usr/local/bin/settle-nightly 2>&1 | less
```

The services read whether they are having a bad night from
`$SETTLE_ROOT/upstream`: `echo 2 > accounts-fail-page` fails settle-accounts on
page 2, `touch chargebacks-down` fails settle-chargebacks, and
`echo 0.05 > convert-delay` makes conversion slow enough to kill by hand.

</details>

<details>
<summary>Hint 3 — what bash does not tell you</summary>

A pipeline's status is its last command's, unless `pipefail` is set. `local
x=$(cmd)` has the status of `local`, which is 0, so `set -e` never sees `cmd`
fail. `$(ls)` is split on spaces before the loop sees it. A file written in
place exists, half-written, the moment a run is killed — and a later run cannot
tell it from a finished one. `>>` on a second run adds a second copy.

Each of those is in the job as it should be except one.

</details>

## What actually happened

| Fault | What was changed | What the log shows | The tell |
|---|---|---|---|
| split | the batch loop became `for name in $(ls "$inbox")` | `done, 2 batches`, exit 0 | `ls` shows three files; `amex late.csv` became `amex` and `late.csv`, neither a file, and the `[ -f ]` guard skipped both |
| pipefail | `set -euo pipefail` became `set -eu` | `settle-accounts: ERROR page 2: HTTP 503` above `done` | heron, finch and gannet have no account in the report; `\| sort` exited 0 |
| errexit | `local cb; cb=$(settle-chargebacks)` became `local cb=$(settle-chargebacks)` | `settle-chargebacks: ERROR … connection reset` above `done` | no chargebacks deducted: bluebird, egret and heron overpaid |
| trap | conversion written straight to `*.sum`, and the cleanup trap removed | `exit 143 (timeout: sent TERM)`, then a clean retry | `amex late.sum` is a few lines of a 40-row batch, and the retry reused it |
| rerun | the report built with `>>` on the published file | two runs last night, both `done` | 16 merchant lines for 8 merchants; `uniq -d` finds every one |

The red herring, every run: settle-rates prints
`ERROR rates-mirror.internal:8443: connection refused; falling back to primary`
on every night, good and bad. The primary answered. It is the first `ERROR` in
the log and it is innocent — and on the rerun night, it is why on-call ran the
job a second time.

<details>
<summary>Solution</summary>

Repair the one line, then rebuild last night from the inbox. `work/<day>` is
the cache the next run trusts, so it goes too: for the trap fault it holds the
truncated batch.

```bash
day=$(date -d yesterday +%F)
job=/usr/local/bin/settle-nightly

# split: let the glob produce the names, quoted
#   for f in "$inbox"/*.csv; do

# pipefail: the pipeline fails if any stage fails
#   set -euo pipefail

# errexit: declare, then assign, so the assignment's status is the command's
#   local cb
#   cb=$(settle-chargebacks)

# trap: write beside the file, rename when complete, clean up on any exit
#   trap 'rm -f "$work"/*.part "$report.part"' EXIT
#   settle-convert "$work/rates" < "$f" > "$sum.part"
#   mv "$sum.part" "$sum"

# rerun: build the whole report beside it and rename it into place
#   { echo "merchant,account,payout_cents"; while …; done < "$work/totals"; } > "$report.part"
#   mv "$report.part" "$report"

rm -rf "/srv/settle/work/$day"
SETTLE_DAY=$day "$job"
```

Write-then-rename is the same repair twice, for two readers: the next run reads
`*.sum`, finance reads the report. Neither may ever see half a file.

Then, for example:

```
cause: no pipefail; settle-accounts failed on page 2 and the pipeline's status was sort's
evidence: the settle-accounts 503 in nightly.log above 'done' and exit 0
detection: payout lines with a blank account > 0 in the published report
```

</details>

## Carrying this forward

- **"Exited 0" is a claim about the last command.** Read every line a run
  printed before trusting the line that says it finished.
- **Count what went in against what came out.** Batches in the inbox against
  batches settled, merchants in the batches against lines in the report — the
  cheapest check that catches three of these five.
- **A file that is read must be written somewhere else first.** Anything the
  next run or the next team trusts appears complete or not at all.
- **Assume every job runs twice and gets killed once.** The scheduler will do
  both, and so will the person on call.

Run the lesson again. The fault moves, and the questions do not.
