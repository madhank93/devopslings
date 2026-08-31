---
title: "the six megabytes you delete are still in every clone"
---

## The situation

`sprite-tool` is a couple of hundred kilobytes of Python and a sprite atlas that
the art pipeline regenerates every sprint. The atlas is committed each time,
because the renderer has to build without the pipeline. Four sprints in:

```
$ du -sk app/.git/objects
17596	app/.git/objects
```

Seventeen megabytes, of which the working tree needs six. Everyone who clones
pays for all of it, and the next sprint adds another six.

The first thing that comes to mind does not work:

```
$ git rm assets/render.bin && git commit -m 'drop the big atlas'
```

That removes the atlas from the tip. Every earlier commit still contains it, and
a commit is not editable — the blobs stay exactly where they were, reachable
from history, transferred on every clone. The repository is now the same size
*and* missing the file the renderer needs.

## Why binary revisions cost full price

Git stores each version of a file as its own object and packs them with delta
compression, which is why a 10,000-line source file with a one-line change adds
almost nothing. Delta compression works on similarity. A regenerated binary
atlas shares nothing meaningful with the previous one — compressed, encoded,
different byte-for-byte — so each revision packs at close to its full six
megabytes and the history grows linearly with the sprints.

Nothing about that is a bug in git. It is what "keep every version forever"
costs when the versions are unlike each other.

## What LFS actually changes

Git LFS replaces the file's *content* in the repository with a pointer:

```
version https://git-lfs.github.com/spec/v1
oid sha256:1ff65e7cc9…
size 6000000
```

That pointer is what the commit stores — a hundred and thirty bytes. The bytes
themselves go to a separate store on the remote, and a clone fetches only the
versions it checks out. History stops carrying every revision; the checkout
still gets the real file, put back by a filter as it lands in the working tree.

Two commands, and they do different jobs:

- `git lfs track "assets/*.bin"` writes a `.gitattributes` rule. It governs
  **future** commits. Run on its own, the history is unchanged and the clone is
  the same size it was.
- `git lfs migrate import --everything --include="assets/*.bin"` **rewrites the
  existing commits**, converting the blobs they hold into pointers. This is the
  one that makes the repository smaller, and like every rewrite it gives every
  commit a new id.

```
$ git lfs migrate import --everything --include="assets/*.bin" --yes
$ git push --force origin main
```

The force push is not optional and not a shortcut: the branch's commits were
replaced, so the remote's old tip is not an ancestor of the new one. Everyone
with a clone has to re-clone or reset onto the new history, which is the real
cost of this operation and the reason to do it once, deliberately, rather than
per sprint.

## The pointer travels; the bytes have to be pushed

A pointer is committed like any other file, and nothing checks that the object
behind it exists anywhere else. Push only the commits — or push to a remote whose
LFS store you never populated — and the clone succeeds, then dies putting the
file back:

```
Smudge error: … remote missing object 1ff65e7cc9…
error: external filter 'git-lfs filter-process' failed
```

The fix is `git lfs push --all origin main`. An ordinary `git push` to a remote
that speaks LFS carries the objects for the commits it sends, which is why the
solution here needs nothing extra.

## What is left behind

The old blobs do not vanish from the origin the moment you force-push. They stay
in its object database, unreachable, until it repacks or prunes. What changes
immediately is what a *clone* transfers: a fetch sends reachable objects only,
so a new machine gets the small history straight away, and the origin's own disk
catches up on its next gc.

<details>
<summary>Hint 1 — measure the thing you are trying to change</summary>

```
$ du -sk app/.git/objects
```

That number is what a clone transfers. Watch it, not the size of the working
tree.

</details>

<details>
<summary>Hint 2 — tracking is not rewriting</summary>

`git lfs track` only affects commits you make from now on. The four atlases are
already committed; converting them means rewriting the commits that hold them.

</details>

<details>
<summary>Hint 3 — after a rewrite the branch cannot fast-forward</summary>

Every commit has a new id, so `git push` is rejected. `git push --force origin
main` is what publishes the rewritten history — and it carries the LFS objects
with it.

</details>

## Checking yourself

```
$ git clone --no-local remotes/app.git /tmp/check
$ du -sk /tmp/check/.git/objects        # kilobytes, not megabytes
$ sha256sum /tmp/check/assets/render.bin
$ git -C /tmp/check lfs ls-files
```

`--no-local` matters: a clone from a path on the same disk copies the object
store wholesale, dead objects included, so it would measure the origin's disk
rather than a real fetch.

<details>
<summary>Solution</summary>

```sh
cd app
git lfs install --local

# Rewrite the existing commits: this is what takes the blobs out of the history.
git lfs migrate import --everything --include="assets/*.bin" --yes

# New commit ids, so the branch cannot fast-forward. The push carries the
# LFS objects to the remote's store.
git push --force origin main
```

</details>
