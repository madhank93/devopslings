---
title: "the loop, done once so the history says what happened"
---

## The situation

Everything else in this module is recovery: finding the commit that broke
something, getting back a branch you reset away, pulling a secret out of
history. All of it reads the history you left behind. This lesson is the part
where you leave it.

The loop is three commands and you have probably run them a hundred times:

```
$ git checkout -b add-healthcheck
$ git commit
$ git merge add-healthcheck
```

Run exactly that here and the history comes out wrong — not broken, not lossy,
just silent about something it could have recorded for free.

## Branch and commit

A branch is a name pointing at a commit. Creating one costs nothing and copies
nothing:

```
$ git checkout -b add-healthcheck
Switched to a new branch 'add-healthcheck'
```

`main` still points where it did. You now have two names for the same commit,
and the one you are standing on moves forward as you commit.

Two commits, each one thing:

```
$ git add healthcheck.sh
$ git commit -m 'feat: add healthcheck script'
$ git add README.md
$ git commit -m 'docs: document the healthcheck'
```

`add-healthcheck` has moved twice. `main` has not moved at all — nobody else has
committed to it while you worked. Hold onto that, because it decides what the
next command does.

## The merge that leaves no trace

```
$ git checkout main
$ git merge add-healthcheck
Updating 7159e00..85d4c58
Fast-forward
```

"Fast-forward" is git telling you it did not merge anything. `main` was an
ancestor of the branch — every commit `main` had, the branch had — so there was
nothing to combine. Git just slid `main`'s pointer up to the branch tip:

```
$ git log --oneline --graph
* 85d4c58 docs: document the healthcheck
* f7dd4e8 feat: add healthcheck script
* 7159e00 c0: payments-api
```

Your work is all there. Nothing was lost. But look at what that history says
now: three commits in a row, indistinguishable from three commits typed straight
onto `main`. The branch is not in the picture. Which two commits belonged
together, that they were reviewed as a unit, the moment they landed on the
deployed branch — none of it was written down, because a fast-forward writes
nothing. It only moves a pointer.

## What --no-ff records

```
$ git merge --no-ff -m 'merge: add-healthcheck into main' add-healthcheck
Merge made by the 'ort' strategy.

$ git log --oneline --graph
*   88d63bb merge: add-healthcheck into main
|\
| * 85d4c58 docs: document the healthcheck
| * f7dd4e8 feat: add healthcheck script
|/
* 7159e00 c0: payments-api
```

`--no-ff` says: make the merge commit even though you do not have to. That
commit is the only new thing here, and what makes it different from every other
commit is that it has **two parents**:

```
$ git rev-list --parents -n 1 HEAD
88d63bb 7159e00 85d4c58
```

Three hashes: the commit, then its first parent (where `main` was) and its
second parent (the branch tip). A commit with two parents is a statement about
history rather than about files — it says *these two lines of development became
one here*.

That gives you three things the straight line did not have:

- **Which commits were a unit.** Everything reachable from the second parent and
  not the first is the branch's work. That is what `git log main..add-healthcheck`
  means, and it is how a reviewer sees the change as a change.
- **When it landed.** The merge commit is dated when it was integrated, which is
  usually not when the work was written.
- **A boundary to undo.** `git revert -m 1 <merge>` backs out the whole feature
  as one operation. With a fast-forward there is no single commit that means
  "the feature", only a run of commits you have to identify by eye.

## When a fast-forward is fine

Often. A one-commit typo fix does not need a merge bubble, and a history where
every trivial change gets one is harder to read, not easier. Plenty of teams set
`--ff-only` deliberately and keep their history linear on purpose — that is a
real position, and rebase is how they get there.

The point is not that `--no-ff` is always right. It is that the default is a
choice being made for you, silently, based on whether `main` happened to move
while you worked. If `main` *had* moved, that same `git merge` would have built
a merge commit without being asked. Knowing which one you are getting, and why,
is the difference between a history you wrote and one that happened to you.

<details>
<summary>Hint 1 — the branch and the two commits</summary>

```
$ git checkout -b add-healthcheck
```

Then create `healthcheck.sh`, `git add` it and commit with the exact subject
`feat: add healthcheck script`. Then append a line to `README.md`, and commit
that separately as `docs: document the healthcheck`.

</details>
<details>
<summary>Hint 2 — the merge has to be recorded</summary>

Back on `main`, a plain `git merge` prints `Fast-forward` and creates no commit.
The flag that forces the merge commit is `--no-ff`.

```
$ git checkout main
$ git merge --no-ff -m 'merge: add-healthcheck into main' add-healthcheck
```

</details>
<details>
<summary>Hint 3 — count the parents</summary>

```
$ git rev-list --parents -n 1 HEAD
```

Three hashes on the line means two parents, which means the tip is a merge
commit. One parent means you fast-forwarded — reset `main` back to the first
commit and merge again.

</details>

## Checking yourself

- Why did `git merge` fast-forward here, and what would have changed if a
  colleague had pushed to `main` while you worked?
- What does `git log main..add-healthcheck` list, and why is that hard to ask
  after a fast-forward?
- `--squash` also puts the work on main. What does it leave out?
- When would you *want* the fast-forward?

<details>
<summary>Solution</summary>

```sh
git checkout -b add-healthcheck

cat > healthcheck.sh <<'H'
#!/bin/sh
curl -sf http://localhost:8080/health
H
chmod +x healthcheck.sh
git add healthcheck.sh
git commit -m 'feat: add healthcheck script'

echo "Run healthcheck.sh to check the service is up." >> README.md
git add README.md
git commit -m 'docs: document the healthcheck'

git checkout main
# main has not moved, so a plain merge would fast-forward and record nothing.
git merge --no-ff -m 'merge: add-healthcheck into main' add-healthcheck

cat > merge.md <<'M'
parents: 2
fast_forward: a straight line of the two commits, with no merge commit and nothing marking where they landed
records: that the two commits were one branch, and the point at which it was integrated into main
M
```

</details>
