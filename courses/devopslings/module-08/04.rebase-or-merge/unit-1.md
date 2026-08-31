---
title: "the tests went green and the fix is gone"
---

## The situation

`discount_amount()` in `pricing.sh` has been changed twice, by two people who
did not know about each other.

On `main`, a hotfix. Stacked coupons had pushed a discount percentage over 100
and produced a negative total — the checkout was paying customers — so any
discount is now capped at 90 percent:

```sh
if [ "$pct" -gt 90 ]; then
  pct=90
fi
```

On `tiered-pricing`, cut from `main` before that hotfix landed, a feature.
Subtotals of 10000 or more get ten extra points:

```sh
if [ "$sub" -ge 10000 ]; then
  pct=$(( pct + 10 ))
fi
```

Both edits are in the same function, a few lines apart. Both authors also
appended a line to `tests.sh` covering their own change. So integrating the
branch conflicts in two files at once:

```
$ git checkout tiered-pricing
$ git rebase main
CONFLICT (content): Merge conflict in pricing.sh
CONFLICT (content): Merge conflict in tests.sh
```

## The resolution that hides itself

A conflict is a prompt, and under time pressure the tempting answer is to make
it stop. Git offers exactly that:

```
$ git rebase -X theirs main
Successfully rebased and updated refs/heads/tiered-pricing.
```

No conflict, no editor, no decision. Then:

```
$ sh tests.sh; echo $?
0
```

Green. Ship it.

Except the cap is gone. `-X theirs` did not merge the two versions of
`discount_amount()`; it took one version of the file whole and threw the other
away, and the hotfix was in the part it threw away. A stacked coupon produces a
negative total again, exactly as it did before the fix.

The test suite did not catch it because the test was in the same conflict as
the code it tests. `tests.sh` conflicted too, and `-X theirs` resolved that file
the same way — by keeping one side whole. The line

```sh
check clamp "$(total 200 150)" 20
```

went out with the fix it guards. The suite is green because it no longer asks
the question.

This is the thing worth carrying out of this lesson. **A green suite after a
conflict resolution is weak evidence, because the resolution had the power to
delete the tests.** The stronger check is to name the behaviours that were
supposed to survive and call them yourself:

```
$ sh -c '. ./pricing.sh; total 200 150'
-100
```

## ours and theirs mean something specific

The two strategy options read like "mine" and "yours", which is where people go
wrong, because during a rebase they do not mean what standing on the branch
suggests.

A rebase replays your commits one at a time onto the upstream branch. At each
step the commit already in place — the one being replayed *onto* — is `ours`,
and the commit being replayed is `theirs`. So when you are sitting on
`tiered-pricing` running `git rebase main`:

| | refers to |
|---|---|
| `ours` | `main` — the branch you are rebasing onto |
| `theirs` | your own commit from `tiered-pricing` |

`theirs` is your work. If you reach for `-X ours` thinking it protects what you
just wrote, it discards it.

A merge is the more intuitive direction — on `main`, `git merge tiered-pricing`
makes `ours` main and `theirs` the branch — but note that `ours` is `main` in
*both* cases. The label follows the commit that is already in place, not the
branch you feel you are on.

Either command can integrate this branch correctly. Neither `-X` option can,
because the correct answer is not on either side.

## The answer is in neither version

Both changes belong, and the order they run in is a third decision that neither
author made:

```sh
if [ "$sub" -ge 10000 ]; then
  pct=$(( pct + 10 ))
fi
if [ "$pct" -gt 90 ]; then
  pct=90
fi
```

Bonus first, cap last. A 10000 subtotal at 85 percent becomes 95, then 90 — a
1000 total. Swap the two blocks and the cap looks at 85, leaves it alone, and
the bonus then lifts it to 95: back over the limit the hotfix exists to enforce,
in the one case that combines them.

That case exists only after the integration. It is not in either branch's tests,
because neither branch could see the other's change. Conflicts are where new
behaviour appears, so a resolution is a good moment to add a test rather than
just to restore two.

`tests.sh` gets both lines back — a conflict in a list of independent tests is
almost always resolved by keeping both sides. That is the one place `git
checkout --ours`/`--theirs` reliably has no useful answer.

## Merge or rebase

For this branch, either. The branch has not been pushed anywhere, so rewriting
its commits harms nobody, and the rebase gives `main` a straight line.

The rule that matters is about who else has the commits. Rebasing rewrites them
— new hashes for the same changes — so doing it to a branch someone else has
pulled leaves them holding commits that no longer exist upstream, and their next
`pull` merges the old and new copies into a duplicated history. Public branches
get merged; private branches are yours to rebase.

What neither choice does is decide the conflict for you. Merge and rebase differ
in the shape of the history they leave. They do not differ in whether the hotfix
survives — that is the resolution, and it is yours either way.

<details>
<summary>Hint 1 — let the conflict happen</summary>

```
$ git checkout tiered-pricing
$ git rebase main
```

Both files conflict. Resist `-X ours` / `-X theirs`: they resolve every
conflicted file the same way, and one of those files is the test suite.

</details>
<details>
<summary>Hint 2 — resolve pricing.sh by keeping both blocks</summary>

Neither side's version is right. `discount_amount()` needs the tier bonus and
the cap, in that order — the cap has to be the last thing that touches `pct`, or
the bonus can lift the percentage back over it.

</details>
<details>
<summary>Hint 3 — tests.sh keeps both lines</summary>

Two independent test lines that landed in the same place. Keep `check clamp` and
`check gold_tier` both, then finish the rebase and fast-forward main:

```
$ git add pricing.sh tests.sh
$ git rebase --continue
$ git checkout main && git merge --ff-only tiered-pricing
```

</details>

## Checking yourself

- Why did `sh tests.sh` pass on a tree with the fix missing?
- During `git rebase main` from `tiered-pricing`, which branch is `ours`?
- The branch had been pushed and a colleague had pulled it. What changes?
- Where would you have caught this before it merged, other than in the diff?

<details>
<summary>Solution</summary>

```sh
git checkout tiered-pricing
git rebase main                 # conflicts in pricing.sh and tests.sh

# pricing.sh: both blocks, bonus first so the cap is the last word.
#   if [ "$sub" -ge 10000 ]; then pct=$(( pct + 10 )); fi
#   if [ "$pct" -gt 90 ];   then pct=90;              fi
# tests.sh: keep both added lines.

git add pricing.sh tests.sh
git rebase --continue
git checkout main
git merge --ff-only tiered-pricing

cat > resolution.md <<'R'
integrated_with: rebase
ours_during_conflict: main
why: taking one side whole drops the other side's fix and the test that covered it
R
```

</details>
