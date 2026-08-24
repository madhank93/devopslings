---
title: "who can read this file, and why the group bits did not save you"
---

## The situation

Seven files, two accounts, one question asked seven times: can this user read
that path.

```
$ ls -l /srv/app
-rw-r-----  1 root deploy  config.yml
drwxr-x---  1 root deploy  data
lrwxrwxrwx  1 root root    latest-token -> /srv/app/secrets/token
----r-----  1 dana deploy  notes.txt
drwxr-xr-x  1 root root    public
drwx------  1 root root    secrets

$ id dana
uid=1001(dana) gid=1001(dana) groups=1001(dana),1002(deploy)
$ id sam
uid=1002(sam) gid=1003(sam) groups=1003(sam)
```

Every answer is already determined. Nothing needs to be run to know them, and
the exercise is to be right before you touch anything — because in the case
that matters, the file you are guessing about is one you are not supposed to
open just to find out.

## The kernel checks one class, not the best one

This is the rule that makes two of the seven come out backwards.

When a process opens a file, the kernel picks **exactly one** of three
permission classes and uses only that one:

1. If the process's UID matches the file's owner → use the **owner** bits. Stop.
2. Else if the GID or any supplementary group matches the file's group → use
   the **group** bits. Stop.
3. Else → use the **other** bits.

It is a chain of `if / else if / else`, not a search for permission that works.
The first class that matches is the only one consulted, and if it says no, the
answer is no — even when a later class would have said yes.

So:

```
----r-----  1 dana deploy  notes.txt
```

dana owns this file. dana is also in `deploy`, and the group bits say `r--`.
dana cannot read it. The owner class matched first, the owner bits are `---`,
and the group bits were never looked at. Being in the group is irrelevant once
you are the owner.

The same rule, one step further:

```
-------r--  1 dana deploy  data/report.csv
```

Every other account on the box could read this. Its owner cannot.

The habit worth taking from this: when you own a file and cannot read it, stop
looking at the group. Owning a file is not a privilege level, it is a branch in
an if-statement — and it is the branch that runs first.

## Reaching a file is not the same as reading it

```
drwx------  1 root root  secrets
-rw-r--r--  1 root root  secrets/token
```

The file is world-readable. Nobody but root can read it.

Opening `/srv/app/secrets/token` requires **execute** on every directory in the
path — `/`, `/srv`, `/srv/app`, `/srv/app/secrets` — because on a directory,
`x` means "may traverse", separately from `r`, which means "may list". Any one
missing `x` ends the walk with `EACCES`, and the permissions on the file itself
are never consulted.

This is why a directory's mode is the more important number of the two, and why
`chmod -R o+r` on a tree does approximately nothing if the directory above it is
`0700`.

The symlink is the same fact wearing a disguise:

```
lrwxrwxrwx  1 root root  latest-token -> /srv/app/secrets/token
```

`lrwxrwxrwx` is not permission to anything. A symlink's own mode is ignored
entirely; the kernel resolves the target and applies the target's path walk.
The `rwxrwxrwx` is noise — Linux does not use it, and it is displayed only
because a mode field has to display something.

## What the two ordinary cases show

Not everything here is a trap, and the two straightforward cases are worth
naming because they are the shape most files have.

`config.yml` is `root:deploy 0640`. dana is in `deploy` and is not the owner, so
class 2 applies: `r--`, allowed. sam matches no class but "other", which is
`---`, refused. This is the normal way to share a file with a team.

`public/readme.txt` is `root:root 0644` with every directory above it
traversable. sam reads it. Nothing surprising, which is the point of including
it: a rule you only ever apply to weird cases is a rule you have not learned.

## Root

`/var/backups/dump.sql` is `0600 root:root`, and root reads it — not because
`0600` grants root anything, but because root holds `CAP_DAC_OVERRIDE`, which
bypasses the file permission check entirely.

Worth knowing precisely, because it is the reason testing as root proves
nothing about whether a service account can read its own config. If you check a
permission question by running the command yourself with sudo, you have
answered a different question.

<details>
<summary>Hint 1 — write the class down before the answer</summary>

For each case, work out which of the three classes applies *before* deciding
yes or no: is this user the owner, a group member, or neither? Then read only
those three bits.

Most wrong answers come from reading all nine bits and looking for one that
permits the access.

</details>

<details>
<summary>Hint 2 — walk the whole path</summary>

For the two cases under a subdirectory, check `x` on every component:

```
$ ls -ld / /srv /srv/app /srv/app/secrets
```

A file is reachable only if every directory above it is traversable by that
user.

</details>

<details>
<summary>Hint 3 — the symlink case is the target's question</summary>

`latest-token` and `secrets/token` are the same question asked twice. The link's
own `lrwxrwxrwx` is not consulted.

</details>

## Checking yourself afterwards

Once the predictions are written down, the way to confirm one is to ask as the
user in question rather than as root:

```
$ sudo -u dana cat /srv/app/notes.txt
cat: /srv/app/notes.txt: Permission denied
```

There is also a tool that answers the question without reading the contents,
which matters when the file is one you should not be opening:

```
$ sudo -u dana test -r /srv/app/notes.txt && echo readable || echo refused
refused
```

<details>
<summary>Solution</summary>

```
case1: yes    dana is in deploy; group bits on config.yml are r--
case2: no     sam matches only "other", which is ---
case3: no     dana owns notes.txt; owner bits are ---, and they are the only
              bits consulted
case4: yes    0644, every directory above it traversable
case5: no     secrets/ is 0700 root:root, so the walk stops before the file
case6: no     same file as case5, reached through a symlink
case7: no     dana owns report.csv; owner bits are ---, though every other
              account could read it

decided_by: owner
```

</details>
