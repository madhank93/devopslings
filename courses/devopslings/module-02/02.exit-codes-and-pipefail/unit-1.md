---
title: "the nightly job that reports success and produces nothing"
---

## The situation

`settle-orders` runs at 02:00. It has exited 0 every night this week. The
settlement file has been empty for four days.

```
$ grep -n '|' /usr/local/bin/settle-orders
fetch-ledger "$LEDGER" | grep ',SETTLED,' | awk -F, '{n++; t+=$4} END {printf "%d %.2f\n", n+0, t+0}' > "$OUT"

$ LEDGER=/srv/settle/missing.csv settle-orders
fetch-ledger: /srv/settle/missing.csv: no such ledger
settle-orders: wrote /srv/settle/settlement.out
$ echo $?
0
```

The error is right there on stderr. The script printed it, then said it wrote
the file, then exited 0. And it did write the file:

```
$ cat /srv/settle/settlement.out
0 0.00
```

Zero settled orders totalling nothing, which is indistinguishable from a quiet
night.

## Your objective

Make `settle-orders` report failure when any stage of its pipeline fails, and
keep reporting success — with correct totals — when they all work.

## What you're being graded on

Two runs. Against a missing ledger it must exit **non-zero** and leave no
settlement file behind. Against a good ledger it must exit **0** and write
`3 400.00`.

That second half matters: a script that always fails is not a fix.

<details>
<summary>Hint 1 — `$?` is one command's status, and a pipeline is several</summary>

```
$ false | true; echo $?
0
$ true | false; echo $?
1
```

By default a pipeline's exit status is the status of its **last** command only.
Everything to the left is invisible.

Here the last command is `awk`, and `awk` succeeded — it was handed an empty
stream, processed all zero lines of it, ran its `END` block and printed
`0 0.00`. That is not awk being wrong. Nobody asked awk whether its input was
supposed to be empty.

The whole picture is in `PIPESTATUS`:

```
$ LEDGER=/nope fetch-ledger "$LEDGER" | grep ',SETTLED,' | awk '...' > /dev/null
$ echo "${PIPESTATUS[@]}"
3 1 0
```

Three, one, zero. Only the zero was ever consulted.

</details>

<details>
<summary>Hint 2 — `pipefail`</summary>

```bash
set -o pipefail
```

With it, a pipeline's status is the rightmost **non-zero** status, or zero if
they all succeeded. Combined with `set -e`, the script stops.

```bash
set -euo pipefail
```

- `-e` — exit on an unhandled non-zero status
- `-u` — error on an unset variable, so a typo'd name does not silently become empty
- `-o pipefail` — the pipeline reports failure if any stage failed

One caution worth knowing now rather than later: `grep` exits **1** when it
matches nothing, and under `pipefail` that is a pipeline failure. Here that is
what you want — a ledger with no settled rows is not a successful settlement.
When empty genuinely is legitimate, handle it explicitly:

```bash
... | { grep ',SETTLED,' || true; } | ...
```

Doing that *deliberately*, at the one place it applies, is completely different
from having the whole script silently do it everywhere.

</details>

<details>
<summary>Hint 3 — do not leave a plausible-looking file behind</summary>

The redirect `> "$OUT"` truncates the target **before** the pipeline runs. So
even a run that fails immediately leaves a zero-byte `settlement.out` with a
current timestamp, which the next job downstream cannot distinguish from a real
one.

Write to a temporary file and move it into place only on success:

```bash
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
... > "$tmp"
mv -- "$tmp" "$OUT"
```

`mv` within a filesystem is atomic, so a reader sees either the old file or the
complete new one, never a half-written one.

</details>

<details>
<summary>Solution</summary>

```bash
#!/bin/bash
set -euo pipefail

LEDGER=${LEDGER:-/srv/settle/ledger-$(date +%F).csv}
OUT=/srv/settle/settlement.out

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

fetch-ledger "$LEDGER" \
  | grep ',SETTLED,' \
  | awk -F, '{n++; t+=$4} END {printf "%d %.2f\n", n+0, t+0}' > "$tmp"

mv -- "$tmp" "$OUT"
trap - EXIT

echo "settle-orders: wrote $OUT"
```

```
$ LEDGER=/srv/settle/nope.csv settle-orders; echo "rc=$?"
fetch-ledger: /srv/settle/nope.csv: no such ledger
rc=3
$ ls /srv/settle/settlement.out
ls: cannot access ...: No such file or directory
```

### Why this is a lesson at all

Nothing here was hidden. `fetch-ledger` printed a clear message to stderr and
exited 3. The information was on the screen every night for four days, in a
cron mail nobody reads, next to an exit status of 0 that every piece of
automation *does* read.

Three things worth keeping:

1. **A pipeline has as many exit statuses as it has stages, and reports one.**
   `set -o pipefail` is the difference between "the last thing worked" and "the
   whole thing worked". It belongs at the top of essentially every script.

2. **Empty output is a result, and it is usually indistinguishable from a
   correct quiet result.** The downstream consumer of `0 0.00` has no way to
   know. If a job can legitimately produce nothing, that state needs to be
   expressible as something other than an empty file.

3. **Do not create the output until you have it.** Truncating the target at the
   start of a pipeline means every failure leaves a fresh, empty, plausible
   file. Write to a temp file, `mv` on success.

This is the same shape as `package-held-back` in module 01: exit 0 means the
program finished the job it thought it had, which is not the same as the outcome
you wanted. Both failed silently for days because the monitoring watched the
exit status instead of the result.

</details>
