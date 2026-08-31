---
title: "the submodule directory you fixed, and the commit the parent still records"
---

## The situation

The application logs through a vendored library at `vendor/liblog`, and the
severity has been missing from every line CI produces for a week. The library's
own repository has the fix, and you pulled it into `vendor/liblog` days ago.
Your build has been green ever since:

```
$ cd app && sh test.sh
ok: ERROR: checkout failed: gateway timeout
```

CI builds the same commit of the application and gets the old library:

```
$ git -c protocol.file.allow=always clone --recurse-submodules remotes/app.git /tmp/ci
$ cd /tmp/ci && sh test.sh
FAIL: expected 'ERROR: checkout failed: gateway timeout', got 'checkout failed: gateway timeout'
```

Two clones of the same branch, two different libraries. Nothing is cached and
nothing is stale: the clone is building exactly what the repository says to
build, and what it says is not what is in your directory.

## A submodule is a commit id, not a directory

`vendor/liblog` looks like a directory. In the parent's history it is one line:

```
$ git ls-tree HEAD vendor/liblog
160000 commit ea37d28e5c0f...	vendor/liblog
```

Mode `160000` is a **gitlink**: an entry that names one commit of another
repository. The parent stores no files from the library at all — the url lives
in `.gitmodules`, and the tree stores a single commit id. `git clone
--recurse-submodules` reads that id, clones the library's origin, and checks out
*that commit*, which is why the checkout lands on no branch:

```
$ git -C vendor/liblog status -sb
## HEAD (no branch)
```

That detached HEAD is not a mistake to be repaired; it is the mechanism. The
parent pins a commit, so the submodule is at a commit rather than following a
branch. Everyone who clones gets the same library, at the same point in its
history, no matter what has landed upstream since.

The consequence is the one that bit here: fetching and checking out a newer
commit *inside* `vendor/liblog` changes your working copy and nothing else. The
pinned id in the parent is unchanged, so every clone still gets the old library.
Git says so plainly, though it is easy to read past:

```
$ git status --short
 M vendor/liblog
```

That `M` is not a modified file. It is the gitlink disagreeing with the checkout
under it — the parent records one commit, the directory is at another.

## Recording the new commit

Staging the submodule path stages the pointer, not the library's files:

```
$ git add vendor/liblog
$ git commit -m 'vendor/liblog: record the commit that logs the level'
$ git push origin main
```

The commit that results is tiny — one tree entry changes from one sha to
another — and it is the entire fix, because it is the only part of your work a
clone can see. Until it is pushed, CI still reads the old id; a commit that
exists on your laptop is not what the build server clones.

## Publish the library before the parent that points at it

Nothing checks a gitlink when you commit it. The parent will happily record a
commit that exists only in your `vendor/liblog` directory, and the push will
succeed. The failure arrives later, in someone else's clone:

```
fatal: remote error: upload-pack: not our ref 720082ce...
fatal: Fetched in submodule path 'vendor/liblog', but it did not contain 720082ce...
```

If the commit you want pinned is one you made yourself, push it to the library's
origin first, then commit the parent. The order is the invariant: a gitlink is a
promise that the commit can be fetched, and only a push makes that true.

The tempting shortcut — delete the submodule and copy the library's files in —
does make CI build the right code today. It also throws away the link to the
library's history: the version in use is no longer a commit id anyone can look
up, and the next upstream fix is a manual copy again.

<details>
<summary>Hint 1 — compare what the clone records with what you have</summary>

```
$ git ls-tree HEAD vendor/liblog          # the commit the parent records
$ git -C vendor/liblog rev-parse HEAD     # the commit checked out
```

Two different shas. `git status` shows the disagreement as ` M vendor/liblog`.

</details>

<details>
<summary>Hint 2 — the fix is a commit in the parent</summary>

`git add` on the submodule's path stages the new commit id. The library's files
are not part of the parent's history and never were.

</details>

<details>
<summary>Hint 3 — CI clones the origin</summary>

The grader clones `remotes/app.git`, so the parent commit has to be pushed. If
you had made your own commit inside `vendor/liblog`, it would have to be pushed
to `remotes/liblog.git` first.

</details>

## Checking yourself

```
$ git -c protocol.file.allow=always clone --recurse-submodules remotes/app.git /tmp/check
$ cd /tmp/check && sh test.sh
ok: ERROR: checkout failed: gateway timeout
$ git ls-tree HEAD vendor/liblog          # still mode 160000
```

A clone that has never seen your working tree builds the fixed library, and
`vendor/liblog` is still a submodule.

<details>
<summary>Solution</summary>

```sh
cd app

# Be sure the submodule is at the library's published tip.
git -C vendor/liblog fetch origin main
git -C vendor/liblog checkout FETCH_HEAD

# Stage the pointer — this records the submodule's commit, not its files.
git add vendor/liblog
git commit -m 'vendor/liblog: record the commit that logs the level'

# CI clones the origin, so the parent commit has to be there.
git push origin main
```

</details>
