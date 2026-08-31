---
title: "stop the token at the commit, and know what that is worth"
---

## The situation

A gateway token reached this repository once already. Getting it out meant
rewriting history, and rewriting history did not make the token safe — it had to
be rotated, because every clone taken before the rewrite still had it.

Every step of that is expensive, and all of it descends from one commit. A
pre-commit hook runs before the commit exists, on a machine where nothing has
been shared yet, and refusing there costs nothing.

```
$ git commit -m 'chore: add deploy config'
pre-commit: staged changes add a gateway credential (pgw_live_...).
            Remove it and read it from the environment instead.
$
```

## The hook that blocks all your work

The obvious implementation greps the files:

```sh
#!/bin/sh
grep -rEq 'pgw_live_[0-9a-f]{32}' --exclude-dir=.git . && exit 1
```

It refuses every commit you will ever make in this repository. Not because the
repository contains a token — because *you* do:

```
$ cat .env
PGW_TOKEN=pgw_live_9f2a7c4e1b8d3a6f5e0c2b9d4a7f1e8c

$ cat .gitignore
.env
```

That file is gitignored and has never been committed. It is exactly where a
credential is supposed to live. The hook cannot tell the difference, because it
is looking at the wrong thing: the working tree is what you *have*, and a commit
is made of what you *staged*.

```sh
git diff --cached
```

is the question the hook is actually asking. It ignores untracked files,
ignored files, and unstaged edits, because none of those are about to become a
commit.

## Added lines, not the neighbourhood

The second version greps the staged diff for a word:

```sh
git diff --cached | grep -qi token && exit 1
```

This one blocks a comment added to `src/app.py`, and the reason is worth seeing
once. A diff does not contain only your change — it carries context lines around
it:

```diff
@@ -1,2 +1,3 @@
 def charge(amount, token):
     return gateway.post(amount, token)
+# a comment
```

Two of those three lines were already committed, and one of them says `token`.
Match on added lines only, which is what the leading `+` is for:

```sh
git diff --cached -U0 | grep -qE '^\+.*pgw_live_[0-9a-f]{32}'
```

`-U0` drops the context entirely, and `^\+` matches the added side.

## Match the credential, not the vibe

What is left is the pattern itself, and this repository is built to punish a
loose one:

| in the repo | what a loose pattern does |
|---|---|
| `docs/configuration.md` documents `api_token` and how to rotate it | `token` blocks the docs |
| `tests/fixtures/gateway_response.json` holds a fake `access_token` | `token` blocks the fixtures |
| `package-lock.json` has a 64-character hex `integrity` hash | `[0-9a-f]{32}` blocks every dependency bump |

A hook with false positives does not get fixed. It gets skipped — and the flag
to skip it is one that everybody already knows.

The credential has a shape: a fixed prefix and a fixed length. Match that.
Matching "things that look secret-ish" is a different and much harder problem,
and the tools that attempt it (`gitleaks`, `trufflehog`, your forge's own
scanner) exist precisely because it is hard.

## What the hook is actually worth

Two facts decide that, and neither is about the pattern.

**It is one flag away.** `git commit --no-verify` skips every pre-commit hook.
Not "warns", not "logs" — the hook does not run. Anybody in a hurry, and every
script that commits non-interactively, is already past it.

**It does not travel.** `.git/hooks` is not part of the repository. It is not
committed, and `git clone` does not copy it. A colleague who clones this
tomorrow has no hook at all. (`core.hooksPath` pointed at a committed directory
fixes the distribution half — the repo can carry its hooks — and does nothing
about `--no-verify`.)

So a pre-commit hook is a fast feedback loop, not a control. It tells you within
a second, on your own machine, before anything is shared. That is genuinely
valuable and it is not enforcement.

Enforcement has to sit where the committer's cooperation is not required:

- a `pre-receive` hook on the server, which runs on the receiving end and cannot
  be skipped by the pusher
- the same scan in CI, on the pushed branch, blocking the merge
- push protection on the forge, which rejects the push itself

The local hook and the server-side check are the same pattern in two places, and
that duplication is the point: one is fast and optional, the other is slow and
mandatory. If you have to pick one, pick the one that cannot be skipped.

<details>
<summary>Hint 1 — look at the staged change</summary>

The hook runs before the commit is made, and the thing about to be committed is
the index, not your files:

```sh
git diff --cached -U0
```

Your gitignored `.env` does not appear there. That is the whole reason to use it.

</details>
<details>
<summary>Hint 2 — added lines only</summary>

Even `git diff --cached` shows context lines that were already committed. `-U0`
removes them, and anchoring on `^\+` restricts the match to the added side.

</details>
<details>
<summary>Hint 3 — the pattern is the credential's shape</summary>

`pgw_live_` followed by 32 hex characters. Not the word `token` — the docs and
the test fixtures use it legitimately. Not "32 hex characters" on its own — the
lockfile's integrity hash is 64 of them.

</details>

## Checking yourself

- Why does a working-tree scan block a commit that adds nothing sensitive?
- Your hook refuses the credential. What does `git commit --no-verify` do to it?
- A colleague clones the repository. Are they protected? What decides that?
- If the answer to both of those is "nothing", why write the hook at all?

<details>
<summary>Solution</summary>

```sh
cat > .git/hooks/pre-commit <<'HOOK'
#!/bin/sh
# Scan the staged change, not the working tree: the developer's own .env holds a
# real token and is never committed, so a working-tree scan blocks every commit.
if git diff --cached -U0 | grep -qE '^\+.*pgw_live_[0-9a-f]{32}'; then
  echo "pre-commit: staged changes add a gateway credential (pgw_live_...)." >&2
  echo "            Remove it and read it from the environment instead." >&2
  exit 1
fi
HOOK
chmod +x .git/hooks/pre-commit

cat > rationale.md <<'R'
no_verify: git commit --no-verify skips every pre-commit hook, so the check is advisory
shared: no — .git/hooks is not part of the repository and git clone does not copy it
backstop: the same pattern has to run server-side, in CI and in push protection on the forge
R
```

</details>
