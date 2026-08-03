---
title: "you added them to the group and it still says permission denied"
---

## The situation

dana needs to read the deploy manifest. You added dana to the `deploy` group
twenty minutes ago. dana says it still does not work, and you have both checked
the obvious thing:

```
$ id dana
uid=1001(dana) gid=1001(dana) groups=1001(dana),1002(deploy)

$ ls -l /srv/deploy/manifest.env
-rw-rw---- 1 root deploy 38 Aug  3 09:12 /srv/deploy/manifest.env
```

The user is in the group. The file is owned by the group. The mode grants the
group read and write. And in dana's shell:

```
dana@box:~$ cat /srv/deploy/manifest.env
cat: /srv/deploy/manifest.env: Permission denied

dana@box:~$ id
uid=1001(dana) gid=1001(dana) groups=1001(dana)
```

Two `id` commands, same user, different answers. Neither is lying.

## Your objectives

| file | answer |
|---|---|
| `/root/answers/why` | one of `session`, `cache`, `secondary`, `relabel` |

Then, **without changing any permissions on `/srv/deploy` or its contents**:

1. make dana able to read `/srv/deploy/manifest.env` in a new login session
2. let dana run `/usr/local/bin/deploy-status` as root via `sudo`, and nothing
   else as root

## What you're being graded on

The named mechanism, a fresh session for dana that can read the manifest, and a
sudo grant that is exactly one command wide. The check confirms the file's mode
and group are untouched — they were correct before you started, and "fixing"
them is how this becomes a security finding instead of a support ticket.

<details>
<summary>Hint 1 — two `id` commands, two different answers</summary>

`id dana` and dana's own `id` disagree, and the difference is *where the
information comes from*.

- `id dana` reads `/etc/passwd` and `/etc/group` **now**. It reports what the
  files currently say. It is the configuration.
- `id` inside dana's shell reports that **process's** credentials — the uid,
  gid and supplementary group list the kernel attached to it. It is the state.

Group membership is copied from the configuration into the process at one
moment: login. After that the process carries its own list, and nothing
re-reads `/etc/group` on its behalf. `usermod` edited a file; it has no way to
reach into a running process and add a credential it was not started with.

So the running shell has an accurate snapshot of a group list from before your
change.

</details>

<details>
<summary>Hint 2 — ruling out the other three</summary>

**`cache`** — plausible on a box with `nscd` or `sssd`, where a stale lookup
cache genuinely does cause this. Not here: `id dana` already reports the new
group, so nothing in the lookup path is stale. There is nothing to flush.

**`secondary`** — secondary groups grant file access exactly like the primary
one does. The proof is one command:

```
$ su - dana -c 'id; cat /srv/deploy/manifest.env'
```

A *new* session for dana reads the file. Same user, same secondary group, and
it works — so being secondary is not the obstacle.

**`relabel`** — the file is already group `deploy`, mode `0660`. Changing
ownership would "fix" it by widening access that was already correct, and the
check rejects that.

</details>

<details>
<summary>Hint 3 — the fix, and the one that does not need a new login</summary>

Log out and back in. Any new session builds a fresh group list:

```
$ su - dana
dana@box:~$ id
uid=1001(dana) gid=1001(dana) groups=1001(dana),1002(deploy)
```

The `-` matters: `su dana` switches user without a login shell and can carry
context you did not want. `su - dana` starts a clean login session.

For an existing shell that cannot be restarted — a long job, a screen session
someone does not want to lose — `newgrp` starts a subshell with the group
added:

```
dana@box:~$ newgrp deploy
```

Same rule underneath: it is a *new process* getting a *new* credential set.
Nothing ever mutates the group list of a process that is already running.

</details>

<details>
<summary>Hint 4 — sudo for exactly one command</summary>

Drop a file in `/etc/sudoers.d/` rather than editing `/etc/sudoers`:

```
dana ALL=(root) NOPASSWD: /usr/local/bin/deploy-status
```

Reading it left to right: user `dana`, on `ALL` hosts, may run as `(root)`,
without a password, this one absolute path.

```
$ install -m 0440 /dev/null /etc/sudoers.d/dana
$ visudo -cf /etc/sudoers.d/dana
```

Two things that bite:

- **Mode `0440`.** sudo ignores files in `sudoers.d` that are group- or
  world-writable, and does so quietly.
- **`visudo -c`.** A syntax error in a sudoers file can lock everyone out of
  sudo, including you. Always check before you rely on it.

Use the absolute path. `dana ALL=(root) NOPASSWD: deploy-status` would match
whatever `deploy-status` resolves to in dana's `PATH`.

</details>

<details>
<summary>Solution</summary>

```
$ echo session > /root/answers/why

$ su - dana -c 'cat /srv/deploy/manifest.env'
release=2026.08.03
channel=stable

$ cat > /etc/sudoers.d/dana <<'SUDO'
dana ALL=(root) NOPASSWD: /usr/local/bin/deploy-status
SUDO
$ chmod 0440 /etc/sudoers.d/dana
$ visudo -cf /etc/sudoers.d/dana
/etc/sudoers.d/dana: parsed OK

$ su - dana -c 'sudo -n /usr/local/bin/deploy-status'
fleet: 12 hosts, 12 on release 2026.08.03
```

Nothing about the file changed, because nothing about the file was wrong.

### Why this is a lesson at all

The trap is that every piece of evidence you would normally trust says the
change is already in effect. `id dana` confirms it, `/etc/group` confirms it,
`ls -l` confirms the file is set up for it. The only thing that disagrees is
the process actually doing the work, and the instinct at that point is to
assume the *permissions* are wrong and start widening them. That is how a
support ticket turns into `chmod 777` and an audit finding.

Two ideas, and they generalise well past groups:

1. **Configuration and state are different things, and they diverge.**
   `/etc/group` is configuration. A process's supplementary group list is
   state, copied once at login. The same split explains why a service keeps
   running with a config file you edited, why an exported environment variable
   does not reach an already-running daemon, and why a rotated credential does
   not take effect until something re-reads it. When the file says one thing
   and the running process does another, ask when the process last read it.

2. **Grant the command, not the shell.** `dana ALL=(ALL) NOPASSWD: ALL` would
   have passed the "dana can run deploy-status" test and handed over the box.
   The narrow grant is barely more work and it is the difference between an
   account that can check deployment status and an account that is root. Module
   07 takes this further, into the "safe" single-command grants that still hand
   over a shell because the command itself can spawn one.

</details>
