---
title: "reset --hard on the wrong branch, and the commits that are not really gone"
---

## The situation

Someone ran `git reset --hard` on `main` believing they were on a throwaway
branch. They were not. `main` jumped back to the base commit, and three commits
of work went with it:

```
$ git log --oneline
a1b2c3d  c0: base, shipped v1.0

$ cat VERSION
shipped: v1.0

$ ls feature-a.txt
ls: cannot access 'feature-a.txt': No such file or directory
```

Two features and the v2.0 release are gone from the branch. The files are off
disk, `VERSION` is back to v1.0, and `git log` shows a single commit. It looks
like a morning of work destroyed by one command.

It was not destroyed. It was unreferenced, which is a different and recoverable
thing.

## reset --hard moves a pointer; it does not delete commits

A branch is a pointer to a commit. `git reset --hard <target>` does two things:
it moves the current branch to point at `<target>`, and it makes the working
tree match. What it does *not* do is delete the commits the branch used to point
at. Those commits still exist in the object database, byte for byte. What they
have lost is a *reference* — nothing points to them any more, so `git log`, which
walks backwards from branch tips, never reaches them.

Git keeps a safety net exactly for this: the **reflog**, a log of every value
`HEAD` (and each branch) has held. Every commit, checkout, reset, merge, and
rebase appends a line. The commits your branch abandoned are still named there:

```
$ git reflog
a1b2c3d HEAD@{0}: reset: moving to a1b2c3d
9f8e7d6 HEAD@{1}: commit: release: ship v2.0
5c4b3a2 HEAD@{2}: commit: feat: add feature b
1a2b3c4 HEAD@{3}: commit: feat: add feature a
a1b2c3d HEAD@{4}: commit: c0: base, shipped v1.0
```

`HEAD@{1}` is where `HEAD` was one move ago — the tip of the work, the "release:
ship v2.0" commit, still whole. Recovery is pointing the branch back at it:

```
$ git reset --hard 9f8e7d6        # or: git reset --hard HEAD@{1}
```

`main` now points at the release again, the working tree is restored, and all
three commits are reachable. The reflog entry did not "contain" the work — the
commits never left — it held the *name* that `git log` had lost.

## Why the reflog can do this

Unreferenced commits are not deleted immediately. Git's garbage collector only
removes objects that nothing references *and* that have aged past a grace period
(90 days by default for reflog-reachable commits). Until then, a `reset --hard`,
a deleted branch, an aborted rebase — all of it — is recoverable, because the
reflog keeps a reference alive long enough for you to notice the mistake and
undo it.

This is the reason `reset --hard` is recoverable and, say, `rm -rf` is not: git
almost never destroys a commit you have made. The panic a hard reset causes is
real and the fix is undramatic — read the reflog, find the last good position,
point the branch back.

The one thing that is genuinely unsafe: work you never committed. The reflog
tracks commits and HEAD moves, not your uncommitted working-tree changes. A
`reset --hard` over uncommitted edits does lose them, because there was never a
commit to keep a reference to. Committing early is what makes the safety net
exist.

<details>
<summary>Hint 1 — the commits are in the reflog</summary>

```
$ git reflog
```

Each line is a former position of `HEAD`. The one just before the reset —
`HEAD@{1}` — is the tip of the lost work, the "release: ship v2.0" commit.

</details>

<details>
<summary>Hint 2 — point the branch back</summary>

```
$ git reset --hard HEAD@{1}
```

or use the sha shown next to the release commit in the reflog. Either moves
`main` back to the release and restores the files.

</details>

<details>
<summary>Hint 3 — confirm the whole release is back</summary>

```
$ cat VERSION            # shipped: v2.0
$ ls feature-a.txt feature-b.txt SHIPPED
$ git log --oneline      # all four commits again
```

</details>

## Checking yourself

```
$ git reset --hard HEAD@{1}
$ cat VERSION
shipped: v2.0
$ git log --oneline | wc -l
4
```

The branch is back at the release, and everything the hard reset dropped is
reachable again.

<details>
<summary>Solution</summary>

```sh
# Find the lost tip in the reflog and point main back at it.
git reflog                                  # HEAD@{1} is 'release: ship v2.0'
git reset --hard HEAD@{1}                    # or the sha shown next to it
```

```
recovered_version: shipped: v2.0
found_with: git reflog
```

</details>
