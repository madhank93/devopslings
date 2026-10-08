---
title: "checkout totals were right two hundred commits ago"
---

## The situation

Checkout totals are a cent short. For the sample cart, at the tip of `main`:

```
$ sh total.sh cart.txt
66.39
```

Finance reconciles that cart at 66.40, and at the first commit on `main` that is
what it printed. There are two hundred commits between then and now. There is no
test suite, just `total.sh`, its two helpers under `lib/`, and `cart.txt`.

Somebody on the team has already pointed at one commit in `git log`, the one
titled "rewrite cents() rounding (quick hack, please double-check)", and wants to
revert it.

## Your objectives

- Find the commit that turned 66.40 into 66.39, by binary search rather than by
  reading diffs
- Write the test that drives the search as a file, `bisect-test.sh`, that
  `git bisect run` can use
- Record the commit in `bisect-answer.md`, and leave the repo back on `main`

## What you're being graded on

The grader works out the first bad commit itself, then checks two things.

`bisect-answer.md`, exactly two lines:

```
first_bad_commit: <short or full sha>
found_with: <the git command you ran to find it>
```

The sha has to be the commit that broke the total, and `found_with` has to name
the command that ran your test at each step.

`bisect-test.sh` is replayed: the grader runs `git bisect run` with it, `main` as
bad and the first commit as good, and it has to land on that same commit. A
correct sha found by some other route, with a test that would have pointed
somewhere else, does not pass.

<details>
<summary>Hint 1: a test is an exit code</summary>

`git bisect run <cmd>` checks out a commit, runs `<cmd>` there, and reads its exit
status as the verdict: 0 is good, 1 to 127 is bad. So the test only has to exit 0
when the sample cart totals 66.40, and something else when it doesn't.

Start the search with both ends marked:

```
git bisect start main "$(git rev-list --max-parents=0 main)"
```

`git rev-list --max-parents=0 main` is the first commit, the one with no parent.

</details>

<details>
<summary>Hint 2: bisect named a commit that doesn't make sense</summary>

Look at what it named, and at the commit just before it:

```
git show --stat <sha>
git checkout <sha>~1 && sh total.sh cart.txt; echo "exit $?"
git checkout main
```

A total of 66.39 and a total of nothing are different answers. At some commits in
this history `total.sh` doesn't print a total at all: it dies with a syntax error
or a missing file, for reasons that have nothing to do with the cent. A test that
reports that as "bad" tells bisect the regression is there. A test that reports it
as "good" tells bisect it definitely isn't. Neither is true: that commit simply
can't be tested.

</details>

<details>
<summary>Hint 3: exit 125</summary>

There is a third exit code. **125 means "skip"**: bisect sets that commit aside and
tests a neighbour instead. So the test needs two separate questions: did
`total.sh` run at all, and if it did, was the answer right?

```sh
out=$(sh total.sh cart.txt 2>/dev/null) || exit 125
[ "$out" = "66.40" ]
```

`total.sh` prints the total and exits 0 even when the total is wrong, which is
what lets the test tell "wrong" from "didn't run".

</details>

<details>
<summary>Solution</summary>

```sh
cat > bisect-test.sh <<'T'
#!/bin/sh
out=$(sh total.sh cart.txt 2>/dev/null) || exit 125   # can't test: skip
[ "$out" = "66.40" ]                                   # right: good, wrong: bad
T

git bisect start main "$(git rev-list --max-parents=0 main)"
git bisect run sh bisect-test.sh      # ... <sha> is the first bad commit
git show <sha>                        # c130, "inline TAX_PCT": the + 50 is gone
git bisect reset

cat > bisect-answer.md <<EOF
first_bad_commit: <sha>
found_with: git bisect run sh bisect-test.sh
EOF
```

Two hundred commits take about eight real verdicts, plus nine skips inside the
broken stretches, so seventeen runs in all instead of two hundred. The culprit is c130, "inline
TAX_PCT": inlining the constant also dropped the `+ 50` that rounded tax half up,
so the total now truncates. The commit everyone suspected, c60, rewrites `cents()`
and prints 66.40 just as before.

With the naive test, `[ "$(sh total.sh cart.txt)" = "66.40" ]`, bisect's very first
probe lands in the middle of c85 to c115, where `lib/money.sh` has an unclosed
function and nothing runs. It counts as bad, bisect throws away the whole later
half, and it reports c85 ("start fmt_line helper") as the first bad commit, a
commit that has nothing to do with money. Treat "doesn't run" as good instead
and it walks into c140 to c175, where `lib/tax.sh` was renamed but not re-sourced,
and blames c176, the commit that *fixed* the build.

### The part worth remembering

**Bisect is only as correct as its test.** It trusts every verdict and never
re-checks one. A single wrong "bad" in the first step discards half the history,
and the real culprit with it. It still prints a confident `is the first bad
commit`, so the output alone won't tell you anything went wrong.

**"Can't build" is not "bad".** Real histories are full of commits that don't
compile, don't start, or are missing a file that lands two commits later. Exit
125 is how the test says "no information here". Bisect skips the commit and
narrows from its neighbours. If a whole run of skips surrounds the regression,
bisect says so and lists the candidates instead of guessing.

**Test for the symptom, precisely.** The test here checks one number. A test that
fails for any reason (a crash, a timeout, an unrelated failing assertion) finds
the first commit where *anything* went wrong, which is often not the one you are
looking for.

**The commit message is not evidence.** The commit called "quick hack, please
double-check" was fine. The one called "inline TAX_PCT", which sounds like a
harmless refactor, was the regression. Bisect judges by behaviour and ignores the
message, which is why it beats reading `git log`.

</details>
