---
title: "the test passed sixty-five commits ago and fails now"
---

## The situation

The calculator is wrong. At the tip of `main` its test fails:

```
$ sh test.sh; echo $?
1
```

Sixty-five commits ago, at the very first one, it passed. Somewhere between then
and now, one commit turned `6 * 7` into something that no longer makes 42 — and
the commit messages are no help, because the one that broke it is titled
"simplify the arithmetic in calc.sh", which is exactly what a good change would
be called too.

You could read all sixty-five diffs. You could also `git checkout` commits one at
a time and test each, which is sixty-five tests in the worst case. Both work.
Both are the slow way.

## Binary search over history

`git bisect` finds the breaking commit by halving. You tell it one commit that is
bad and one that is good; it checks out the midpoint between them and asks you
whether that one is good or bad; and it repeats, throwing away half the remaining
range each answer. Sixty-five commits is about six questions, not sixty-five —
`log2(65) ≈ 6`.

By hand:

```
$ git bisect start
$ git bisect bad main                                # the tip is broken
$ git bisect good $(git rev-list --max-parents=0 main)   # the first commit was fine
Bisecting: 31 revisions left to test after this (roughly 5 steps)
[<sha>] c33: add note 33
```

git has checked out the midpoint for you. Run the test, tell git the answer:

```
$ sh test.sh && git bisect good || git bisect bad
```

and it jumps to the middle of the half that still contains the break. Repeat
until:

```
<sha> is the first bad commit
```

## Let the test drive it

When the "is this commit good or bad" question is itself a command — a test that
exits 0 for good and non-zero for bad — you do not have to answer by hand. `git
bisect run` runs the command at each step and reads its exit code as the answer:

```
$ git bisect start
$ git bisect bad main
$ git bisect good $(git rev-list --max-parents=0 main)
$ git bisect run sh test.sh
running 'sh' 'test.sh'
...
<sha> is the first bad commit
```

That is the whole search, unattended. This is why a fast, scriptable test is
worth keeping green: it is not only a gate on new work, it is the probe that
locates old breakage. A regression with a test that reproduces it is a
five-minute `bisect run`; the same regression with no test is an afternoon of
reading diffs.

When you are finished — either way — return to where you started:

```
$ git bisect reset
```

`reset` puts `HEAD` back on the branch you began on. Skipping it leaves you
detached on whatever commit bisect last checked out, which is its own confusing
morning.

## What the commit turns out to be

The first bad commit is the one whose diff changed the behaviour, no matter what
its message claims. Here it is the one that rewrote the arithmetic; bisect names
it exactly, and `git show <sha>` is the diff that did the damage. That is the
output that matters — not "somewhere around here", but the single commit, which
you can then revert, fix forward, or simply understand.

<details>
<summary>Hint 1 — mark the two ends</summary>

```
$ git bisect start
$ git bisect bad main
$ git bisect good $(git rev-list --max-parents=0 main)
```

`git rev-list --max-parents=0 main` is the very first commit — the one with no
parent — which you know was good.

</details>

<details>
<summary>Hint 2 — let the test answer</summary>

```
$ git bisect run sh test.sh
```

The test exits 0 when the calculator is right and non-zero when it is not, so
`bisect run` can drive every step itself.

</details>

<details>
<summary>Hint 3 — record it, then reset</summary>

bisect prints `<sha> is the first bad commit`. Put that sha in `bisect-answer.md`,
then `git bisect reset` to return to `main`.

```
first_bad_commit: <sha>
found_with: git bisect
```

</details>

## Checking yourself

```
$ git bisect run sh test.sh
...
abc1234 is the first bad commit
$ git show abc1234        # the diff that broke it
$ git bisect reset
```

<details>
<summary>Solution</summary>

```sh
git bisect start
git bisect bad main
git bisect good "$(git rev-list --max-parents=0 main)"
git bisect run sh test.sh          # prints: <sha> is the first bad commit
git bisect reset

# record the sha it named
cat > bisect-answer.md <<EOF
first_bad_commit: <the sha bisect printed>
found_with: git bisect
EOF
```

</details>
