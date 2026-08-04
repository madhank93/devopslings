---
title: "the setup script that only works on a machine it has never seen"
---

## The situation

`bootstrap-node` prepares a fresh host. It is run by hand, occasionally twice,
and occasionally interrupted.

```
$ bootstrap-node
bootstrap-node: done

$ bootstrap-node
groupadd: group 'nodeagent' already exists
$ echo $?
9
```

The second run stops at line one. And a run that got half way leaves a host that
this script can no longer finish:

```
$ bootstrap-node          # after a partial run
groupadd: group 'nodeagent' already exists
```

So the script works exactly once, on a host in exactly one state, and every
other situation needs a human to work out which lines have already happened.

## Your objective

Make it idempotent. Running it any number of times, in any combination with
interrupted runs, must reach the same end state and exit 0 every time:

- group `nodeagent`, and system user `nodeagent` in it
- directories `/etc/nodeagent`, `/srv/nodeagent`, `/opt/nodeagent-1.4`
- `/etc/nodeagent/agent.conf` with **exactly** two lines
- `/etc/profile.d/nodeagent.sh` with **exactly** one PATH line

## What you're being graded on

A fingerprint of that whole end state, taken after 1, 2 and 3 runs, and again
after resuming a deliberately half-finished run. All four must match.

<details>
<summary>Hint 1 — what idempotent actually means here</summary>

Not "detects that it ran before". **Running it again reaches the same state.**

The distinction matters because the obvious implementation of the first is a
flag file:

```bash
[ -e /var/lib/bootstrapped ] && exit 0
```

That records that the script *started*, not that the host is correct. It is
wrong in every interesting case: the interrupted run wrote the flag and did
half the work; someone removed a directory by hand; the desired state changed
and you want to re-apply it.

The property you want is that **each step asserts the state it wants**. Then any
prefix of the script can be resumed, in any order, and the flag file is
unnecessary.

</details>

<details>
<summary>Hint 2 — the create-if-absent shape</summary>

```bash
getent group nodeagent >/dev/null || groupadd nodeagent
getent passwd nodeagent >/dev/null || \
  useradd --system --gid nodeagent --no-create-home nodeagent

mkdir -p /etc/nodeagent /srv/nodeagent /opt/nodeagent-1.4
```

`mkdir -p` is already idempotent — that is what `-p` is for, and the reason
`mkdir` without it is a bug in a script that may run twice.

Note the `||` here is deliberate and safe: it is a genuine test, which is
exactly the context `set -e` steps aside for. That is the previous lesson's rule
being used correctly rather than tripped over.

</details>

<details>
<summary>Hint 3 — appending is never idempotent</summary>

```bash
echo "endpoint=..." >> /etc/nodeagent/agent.conf
```

Three runs, six lines. This is the single most common cause of "the config has
two of everything", and it appears in `authorized_keys`, `/etc/hosts`, `sudoers`
drop-ins, `.bashrc` and every `profile.d` file ever written by a setup script.

Declare the whole file instead of adding to it:

```bash
cat > /etc/nodeagent/agent.conf <<'CONF'
endpoint=https://collector.internal:8443
queue_dir=/srv/nodeagent
CONF
```

Writing the complete file is idempotent by construction — the end state does not
depend on what was there before.

If you must genuinely append to a file you do not own, make the append
conditional on the line's absence:

```bash
grep -qxF "$line" "$file" || printf '%s\n' "$line" >> "$file"
```

</details>

<details>
<summary>Hint 4 — write via a temp file</summary>

```bash
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<'CONF'
...
CONF
mv -- "$tmp" /etc/nodeagent/agent.conf
```

`cat > /etc/nodeagent/agent.conf` truncates the target immediately, so a run
interrupted mid-write leaves a half-written config that the agent will happily
load. `mv` within a filesystem is atomic: a reader sees the old file or the
complete new one.

That also makes this step safe to interrupt, which is the property the whole
exercise is about.

</details>

<details>
<summary>Solution</summary>

```bash
#!/bin/bash
set -euo pipefail

getent group nodeagent >/dev/null || groupadd nodeagent
getent passwd nodeagent >/dev/null || \
  useradd --system --gid nodeagent --no-create-home nodeagent

mkdir -p /etc/nodeagent /srv/nodeagent /opt/nodeagent-1.4

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
cat > "$tmp" <<'CONF'
endpoint=https://collector.internal:8443
queue_dir=/srv/nodeagent
CONF
cmp -s "$tmp" /etc/nodeagent/agent.conf 2>/dev/null || mv -- "$tmp" /etc/nodeagent/agent.conf

tmp2=$(mktemp)
printf 'export PATH="$PATH:/opt/nodeagent-1.4/bin"\n' > "$tmp2"
if cmp -s "$tmp2" /etc/profile.d/nodeagent.sh 2>/dev/null; then
  rm -f "$tmp2"
else
  mv -- "$tmp2" /etc/profile.d/nodeagent.sh
fi

echo "bootstrap-node: done"
```

The `cmp` is optional — moving the file unconditionally is equally idempotent.
It is there so a no-op run does not change the file's mtime, which matters when
something else is watching for changes.

### Why this is a lesson at all

The script was written by someone provisioning a host, and it was correct for
that: a fresh machine, a single run, watched. It became wrong when it entered
the world, where it gets run twice because the first run's output scrolled
away, and interrupted because a laptop closed, and re-run six months later
against a host that has drifted.

Two ideas worth keeping:

1. **Describe the desired state, do not perform a sequence of changes.** "Make
   sure this file contains exactly this" survives being run twice.
   "Add this line" does not. This is the whole argument for configuration
   management, and it is why module 15's Ansible lesson grades on `changed=0`
   for the second run rather than on the end state alone — a tool that cannot
   tell you it changed nothing cannot tell you it converged.

2. **The state a script most often meets is one it half-created.** Interrupted
   runs are normal, not exceptional. A script that only works on a pristine
   host cannot recover from its own interruption, which means every failure
   needs a human to work out where it got to — at the worst possible time.

</details>
