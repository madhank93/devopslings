---
title: "set -e is at the top and the failure went through anyway"
---

## The situation

`provision-tenant` begins with the line everyone knows to write:

```bash
#!/bin/bash
set -euo pipefail
```

It provisioned a tenant last night whose database was never created:

```
$ touch /srv/tenants/fail-create-db
$ provision-tenant
tenant-step: create-db failed
tenant-step: create-schema ok
provision: schema ready
...
provision: tenant is ready
$ echo $?
0
```

The first step failed, said so, and the script carried on through three more
steps and declared success.

`set -e` is not broken. It is doing exactly what it is specified to do, and
this script manages to hit all four contexts where that specification says to
stand aside.

## Your objective

Make the script stop and exit non-zero when any of its four steps fails — and
still print `provision: tenant is ready` and exit 0 when they all succeed.

Keep all four steps, in order.

## What you're being graded on

Five runs: each of `create-db`, `create-schema`, `create-user` and `seed-data`
made to fail in turn, then one with everything healthy. Each failing run must
stop at that step. The healthy run must complete.

<details>
<summary>Hint 1 — the rule behind all four</summary>

From `man bash`, `set -e` does not apply when a command is part of a construct
whose purpose is to **test** a status.

That is not an arbitrary exception. A shell that aborted inside an `if`
condition could never run an `if` statement at all.

The four places it applies:

| context | why suspended |
|---|---|
| the condition of `if`, `while`, `until` | you are testing the status |
| the left of `&&` or `\|\|` | you are testing the status |
| any command with `!` in front | you are testing the status |
| `local x=$(cmd)` / `export` / `declare` | the status is `local`'s, and `local` succeeded |

Suspension is **recursive**: if a function is called as a condition, `set -e` is
off for everything inside it, however deep.

</details>

<details>
<summary>Hint 2 — the first two, which look deliberate</summary>

```bash
if tenant-step create-db; then
  echo "provision: database ready"
fi
```

Reading it aloud: "if creating the database succeeds, say so." And if it fails?
Nothing. There is no `else`. The `if` consumed the status and threw it away.

The fix is to notice the `if` was never doing anything:

```bash
tenant-step create-db
echo "provision: database ready"
```

Same for `&&`:

```bash
tenant-step create-schema && echo "provision: schema ready"
```

`cmd && echo` is a very common way to write "do this, then say so", and it
silently converts a fatal error into a skipped message.

If you genuinely want to handle a failure rather than abort, be explicit:

```bash
if ! tenant-step create-db; then
  echo "provision: could not create the database" >&2
  exit 1
fi
```

</details>

<details>
<summary>Hint 3 — the one that is genuinely hard to see</summary>

```bash
make_creds() {
  local creds=$(tenant-step create-user)
  ...
}
```

Test the two forms against each other:

```
$ bash -c 'set -e; x=$(false); echo REACHED'          # prints nothing, rc=1
$ bash -c 'set -e; f(){ local x=$(false); }; f; echo REACHED'   # prints REACHED, rc=0
```

A **plain** assignment propagates the command substitution's status. Adding
`local` does not. `local` is itself a command, it succeeded, and its status is
what the shell sees.

So the bug is introduced by the thing you were told was good practice. `export
x=$(cmd)` and `declare x=$(cmd)` behave identically.

Declare first, assign second:

```bash
local creds
creds=$(tenant-step create-user)
```

</details>

<details>
<summary>Hint 4 — the fourth, and why it is worse than it looks</summary>

```bash
seed() {
  tenant-step seed-data
  echo "provision: seeded"
}
if seed; then
```

`seed` is called as a condition, so `set -e` is suspended for the entire call —
including `tenant-step seed-data` *inside* it. The function keeps going after
the failure, prints "seeded", and returns 0 because `echo` succeeded.

This is the dangerous one, because the suspension happens at the call site and
the damage happens somewhere else entirely. A function that is perfectly safe
when called normally silently stops checking anything when someone later wraps
it in an `if`. Nothing about the function changes; nothing about it warns you.

```bash
seed
echo "provision: seed step returned"
```

</details>

<details>
<summary>Solution</summary>

```bash
#!/bin/bash
set -euo pipefail

tenant-step create-db
echo "provision: database ready"

tenant-step create-schema
echo "provision: schema ready"

make_creds() {
  local creds
  creds=$(tenant-step create-user)
  echo "provision: creds=${creds:-none}"
}
make_creds

seed() {
  tenant-step seed-data
  echo "provision: seeded"
}
seed
echo "provision: seed step returned"

echo "provision: tenant is ready"
```

Every fix is the same fix: stop using a testing construct for something that is
not a test.

### Why this is a lesson at all

`set -euo pipefail` has become a thing people paste at the top of scripts as a
talisman, and it is genuinely worth pasting. The problem is what it produces:
confidence. The author of this script believed failures were being caught, so
they did not check any statuses themselves — and the four constructs that
suspend `set -e` are also four of the most idiomatic things to write.

Three things worth keeping:

1. **`set -e` is a safety net, not a guarantee.** It catches the failures you
   did not think about, in the places it applies. For anything that must not
   silently proceed, check it explicitly.
2. **`local x=$(cmd)` is the one to memorise.** The other three at least look
   like tests. This one looks like good hygiene and is the reason the failure
   was invisible.
3. **Suspension is inherited by everything a condition calls.** Wrapping a
   function in `if` disables error checking throughout its whole body. That is
   almost never what the person adding the `if` intended.

`shellcheck` finds several of these, and is worth running over anything
scheduled. It will not find all of them — which is why knowing the rule matters
more than knowing the tool.

</details>
