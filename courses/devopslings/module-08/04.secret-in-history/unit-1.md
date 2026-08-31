---
title: "A live token, deleted three weeks ago and still in every clone"
---

## The situation

A payment-gateway token went into `deploy/config.yml` three weeks ago. Someone
noticed, and fixed it the obvious way:

```
$ git log --oneline
e34f4b9  feat: handler 8
...
3b83c5a  chore: move deploy config to env vars     <- the "fix"
...
```

The tip is clean. The file is not on disk, `grep -r pgw_live .` finds nothing,
and the config now comes from the environment. It looks handled.

```
$ git log --oneline -S 'pgw_live_9f2a7c4e1b8d3a6f5e0c2b9d4a7f1e8c'
3b83c5a  chore: move deploy config to env vars
a768b9d  chore: add deploy config
```

It is not handled. It is in the history, which means it is in every clone.

## A commit that deletes a file keeps the file

Git stores snapshots, not patches. Every version of every file ever committed is
a **blob** in the object database, addressed by the hash of its contents. A
commit that removes a file writes a new tree that does not mention that blob —
and that is all it does. The blob itself is untouched, still reachable through
the older commits that do mention it.

So `git rm` plus a commit changes exactly one thing: the file stops being in the
*tip*. Anyone who clones gets the whole object graph, walks back two commits, and
reads the token. Anyone who cloned three weeks ago already has it. `git rm` is
the right operation for a file you no longer want and the wrong one for a secret.

Getting the value out means the commits that contain it must stop existing — they
have to be **rewritten**, replaced by new commits with new hashes whose trees
never point at that blob.

## Rewriting history with --index-filter

`git filter-branch` walks the history and rebuilds each commit through a filter
you supply. The filter that matters here is `--index-filter`: it runs against the
*index* of each commit, so git never has to check a tree out to disk.

```
$ git filter-branch -f \
    --index-filter 'git rm --cached --ignore-unmatch deploy/config.yml' \
    --prune-empty -- --all
```

Piece by piece:

- **`--index-filter '…'`** — the command run for every commit. `git rm --cached`
  drops the file from that commit's index; `--ignore-unmatch` keeps it from
  failing on the commits where the file was not there yet. A `--tree-filter`
  would do the same thing by checking every commit out — correct, and orders of
  magnitude slower.
- **`--prune-empty`** — the commit whose only content was adding that file now
  changes nothing. Drop it rather than keep an empty commit.
- **`-- --all`** — everything after `--` goes to `rev-list`. `--all` means every
  ref, not just the current branch: a tag or another branch holding the old
  commits would keep the secret alive.

Every rewritten commit gets a new hash, so this rewrites the identity of the
history from the first affected commit onward. On a shared branch that is a
disruptive act — everyone re-clones or resets — which is the real reason people
try `git rm` first.

`git-filter-repo` is the modern, faster, and officially recommended tool for
this, and it cleans up after itself better than `filter-branch` does. It is a
separate install, though; `filter-branch` ships with git, which is what you have
on a machine where the leak was just discovered.

## The half that is easy to miss

Run the rewrite, and the token is still there:

```
$ git rev-list --objects --all | awk '{print $1}' | git cat-file --batch | grep -c pgw_live
1
```

`filter-branch` does not throw the old history away. It saves each pre-rewrite
tip as a backup ref under `refs/original/`:

```
$ git for-each-ref refs/original
9f8e7d6 commit refs/original/refs/heads/main
```

That is a real ref. It reaches the old commits, the old commits reach the old
trees, and the old trees reach the blob. Until it is deleted, the rewrite has
changed nothing about whether this repository contains the secret:

```
$ git for-each-ref --format='%(refname)' refs/original |
    while read ref; do git update-ref -d "$ref"; done
```

Now nothing references the old commits. To stop the objects being *stored* here
at all, drop the reflog entries that also still name them and collect the
garbage:

```
$ git reflog expire --expire=now --all
$ git gc --prune=now
```

The order matters and the reason is worth holding on to: an object survives as
long as *anything* points at it — a branch, a tag, a backup ref, a reflog entry.
"I deleted it" is a claim about references. Whether it is true is a question
about all of them.

## Removal is not the fix

Suppose all of that works perfectly. The repository is clean, the objects are
gone, `git log -S` finds nothing.

The token is still valid.

Rewriting history is an edit to *your copy* of the object graph. It does not
reach: the clone on a laptop that pulled last week, the fork, the CI cache, the
backup, the mirror on the internal server, the build log that echoed the config,
or whoever already read it. A secret that has been committed to a repository has
to be treated as disclosed from the moment it was committed — the only action
that makes it safe is **revoking it at the issuer and reissuing a new one**.

The purge is still worth doing. It stops the next person from finding it, and it
is what you owe anyone who clones tomorrow. But it is cleanup after the incident,
not the response to it. Rotation is the response. Do it first — a rewrite takes
minutes to plan and a revoke takes seconds.

<details>
<summary>Hint 1 — find where the value actually lives</summary>

```
$ git log --oneline -S 'pgw_live_9f2a7c4e1b8d3a6f5e0c2b9d4a7f1e8c'
```

`-S` searches the content of every commit's diff, not the tip. Two commits
carry the value: the one that added the file and the one that deleted it.

</details>

<details>
<summary>Hint 2 — rewrite, don't delete</summary>

```
$ git filter-branch -f \
    --index-filter 'git rm --cached --ignore-unmatch deploy/config.yml' \
    --prune-empty -- --all
```

`--index-filter` edits each commit's index without checking out a tree.
`-- --all` makes it cover every ref, not just the current branch.

</details>

<details>
<summary>Hint 3 — check what still points at the old commits</summary>

```
$ git for-each-ref refs/original
```

`filter-branch` keeps your pre-rewrite tips there as a backup. While those refs
exist, the old commits — and the blob — are still reachable.

</details>

## Checking yourself

Scan every object reachable from every ref:

```
$ git rev-list --objects --all | awk '{print $1}' |
    git cat-file --batch | grep -c pgw_live
0
$ git log --oneline | wc -l
10
$ ls handler_8.py deploy/README.md
```

Zero reachable objects hold the value, and the rest of the work — every handler
commit, the initial commit, the tip's files — came through the rewrite intact.

<details>
<summary>Solution</summary>

```sh
# 1. Rotate first: revoke pgw_live_9f2… at the gateway and issue a new token.

# 2. Rewrite every commit, dropping the file that held it.
git filter-branch -f \
  --index-filter 'git rm --cached --ignore-unmatch deploy/config.yml' \
  --prune-empty -- --all

# 3. Delete the backup refs filter-branch left behind, or the old commits
#    are still reachable and nothing has changed.
git for-each-ref --format='%(refname)' refs/original |
  while read ref; do git update-ref -d "$ref"; done

# 4. Stop this clone from storing the objects at all.
git reflog expire --expire=now --all
git gc --prune=now
```

```
purged_with: git filter-branch --index-filter
rotated: yes
why: the token was already pushed and cloned, so rewriting my history does not invalidate the credential
```

</details>
