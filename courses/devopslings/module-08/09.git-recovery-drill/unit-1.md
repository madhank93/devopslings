---
title: "the release check fails, and the cause is somewhere in the history"
---

## The situation

```
$ sh release-check.sh
```

It should end `release check: PASS`. It does not. That is the entire ticket,
and it will be the entire ticket every time you run this lesson — because the
fault is drawn at random from five, and each is a different way a repository
loses, breaks or leaks work.

The check clones `remotes/app.git` the way CI does, prints the receipt total
for a reference cart (it should be `1,512.08`), and scans the history of every
branch for a live gateway token. Your working copy is `app/`; its submodule
`vendor/fmt` comes from `remotes/fmt.git`. The payment gateway's token API is
`./issuer`.

You cannot memorise the answer. You can memorise the order of the questions.

## Your objectives

- Make the release check pass by repairing what went wrong, at its cause, and
  pushing the repair to `remotes/`
- Write `triage.md`, three lines:

  ```
  cause:     <what happened, in a few words>
  evidence:  <the command that proved it>
  detection: <a signal and a threshold that would have caught it first>
  ```

## What you're being graded on

The grader runs its own copy of the release check against a fresh clone, so
editing `release-check.sh` changes nothing. Then it checks that the repair is at
the cause rather than around it:

- **origin main kept its history.** Resetting main to an older commit or branch
  and replaying on top loses work that was there when the ticket came in.
- **each rule is right where it lives.** `tax`, `discount` and `shipping` are
  called on their own, so a total patched inside `checkout()` does not pass.
- **`vendor/fmt` is still a submodule**, pinned to a commit on
  `remotes/fmt.git`'s main that contains the separator fix. A `fmt_money`
  redefined in `lib.sh` makes the total right and leaves the pin wrong.
- **lost commits come back as themselves**, with their original hashes, not
  as copies with the same content.
- **no ref reaches a leaked value, and the value no longer works** at `./issuer`.
- **`docs/example.env` is untouched.** It looks like a credential and is not.

And `triage.md`: `cause` must describe the fault that was seeded (for a
regression, it names the commit's sha); `evidence` must be the command that
proves that fault; `detection` must name a signal that fits it *and* a number.

<details>
<summary>Hint 1 — the questions, in order</summary>

```
$ git -C app log -g --oneline main | head        # has main been somewhere it no longer is?
$ git -C app log --oneline -- vendor/fmt        # has the pin moved, and which way?
$ git -C app log --merges --oneline             # then git show <merge> for each
$ git -C app bisect start main <first-commit>   # when did the behaviour change?
$ git -C app log -p --all -S pgw_live_          # what should never have been committed?
```

The total alone tells you something went wrong, not what. Four of the five
faults change the same number, and each changes it by a different amount; the
fifth leaves it right and fails the scan.

</details>

<details>
<summary>Hint 2 — "merged" is a claim about ancestry, not content</summary>

`git branch --merged` and `git log` will tell you the hotfix branch is part of
main. That is true of any merge, including one resolved by keeping only one
side. What a merge *brought in* is `git diff <merge>^1 <merge>`; what the branch
changed is `git diff <merge-base> <branch>`. When the first is missing the
second, the merge dropped it.

The same trap in another shape: `git submodule status` without a `+` means your
checkout matches what the parent records. It does not mean what the parent
records is right.

</details>

<details>
<summary>Hint 3 — repairing rather than routing around</summary>

- a lost tip goes back with `git reset --hard <sha from the reflog>`, and the
  push is then a fast-forward
- a regression is reverted, or fixed by hand, once bisect has named it — and the
  commit is what goes in `cause`
- a dropped side is re-applied: `git cherry-pick <the hotfix commit>`
- a gitlink moves with `git add vendor/fmt` after checking out the right commit
  inside it
- a leaked value is rewritten out of every branch, force-pushed, and revoked;
  only the file that held it is removed

</details>

## What actually happened

| Fault | What was done | The total | The tell |
|---|---|---|---|
| reflog | `reset --hard HEAD~3` on main, force-pushed | `1,527.08` — flat shipping is back | `git log -g main` holds a tip main no longer contains |
| bisect | `lib: simplify tax arithmetic` truncates instead of rounding half up | `1,512.07` | a cent; `git bisect run` names the commit in five steps |
| merge | `Merge branch 'hotfix/coupon-cap'` made with only main's side | `1,080.05` — the 30% cap is gone | the hotfix is an ancestor and its diff is not in main |
| submodule | `chore: refresh vendored libs` moved the `vendor/fmt` pin back | `1512.08` — no separator | `git log -p -- vendor/fmt` shows the gitlink moving backwards |
| secret | a live token committed in `deploy/prod.env`, deleted two commits later | right | `git log -p --all -S pgw_live_` finds the add and the delete |

The red herring, every run: `docs/example.env` holds `pgw_test_000…`, the
gateway's documented placeholder. It turns up in every search for `pgw_`, and a
history rewrite that removes `*.env` removes it too. It was never the fault.

<details>
<summary>Solution</summary>

The reference solution asks the questions in order and repairs at the first one
that answers. From `app/`:

```bash
# secret: the value, the file that held it, then rewrite, push, revoke
git log -p --all -S pgw_live_
../issuer revoke <token>
FILTER_BRANCH_SQUELCH_WARNING=1 git filter-branch -f \
  --index-filter 'git rm -q --cached --ignore-unmatch deploy/prod.env' \
  --prune-empty -- --branches
git for-each-ref --format='%(refname)' refs/original | xargs -n1 git update-ref -d
git push --force origin --all

# reflog: the tip main used to have
git log -g --oneline main
git reset --hard <that sha> && git push origin main

# submodule: pin the published fix
git -C vendor/fmt fetch origin main && git -C vendor/fmt checkout FETCH_HEAD
git add vendor/fmt && git commit -m 'vendor/fmt: back to the separator fix'
git push origin main

# merge: re-apply the side that was dropped
git cherry-pick -x origin/hotfix/coupon-cap && git push origin main

# bisect: find the commit, revert it
git bisect start main "$(git rev-list --max-parents=0 main)"
git bisect run sh -c '. ./lib.sh; [ "$(tax 1019)" = 82 ]'
git bisect reset
git revert --no-edit <first bad commit> && git push origin main
```

Then, for example:

```
cause: regression introduced in 3f2a9c1e: tax rounding changed
evidence: git bisect run
detection: tests in ci on every commit: page on 1 failure
```

</details>

## Carrying this forward

- **Ask about presence before behaviour.** A missing commit, a moved pin and a
  dropped merge side all look like a bug in the code. Bisecting before checking
  the reflog hunts for a commit that is not on the branch.
- **Ancestry is not content.** "Merged", "recorded" and "deleted" are all claims
  about pointers; the diff is the claim about what is actually there.
- **The repair goes where the fault is.** A total patched in `checkout()`, a
  formatter pasted over the submodule, a file deleted at the tip: each makes the
  check pass and leaves the fault for the next person.
- **Leave the alarming thing alone until it is proven guilty.** A placeholder
  that looks like a secret is the easiest thing to destroy during an incident.

Run the lesson again. The fault moves, and the questions do not.
