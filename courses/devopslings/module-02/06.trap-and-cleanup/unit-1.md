---
title: "forty temp directories and 38 GB nobody can account for"
---

## The situation

```
$ ls -d /srv/scratch/build-*
/srv/scratch/build-8Qk2Lm
/srv/scratch/build-Xr4tPd
/srv/scratch/build-9wZbNc
```

`build-index` creates a scratch directory and removes it on its last line:

```bash
work=$(mktemp -d /srv/scratch/build-XXXXXX)
... build the index ...
rm -rf "$work"
echo "build-index: done"
```

That line is correct, and it runs on exactly one of the three ways this script
ends. The build fails sometimes. People press Ctrl-C. Deploys send `SIGTERM`.
None of those reach the last line, and each one leaves a directory behind.

## Your objective

Make `build-index` remove its scratch directory on **every** exit path:

- a normal, successful run
- a failing run (`touch /srv/build/FAIL` makes stage 2 fail)
- an interrupted run (`SIGINT` or `SIGTERM` part way through)

A successful run must still write `200` to `/srv/build/index.out`. Clean up the
existing leftovers too.

## What you're being graded on

All four paths, each run for real: success, failure, `SIGINT` and `SIGTERM`.
Zero `build-*` directories after each. Plus the three that are already there —
fixing the script does not remove what earlier runs left.

<details>
<summary>Hint 1 — cleanup belongs on the way out, not at the end</summary>

"The end of the script" and "the way out of the script" are different places.
Only one of them is guaranteed to be visited.

`trap` registers a command to run when the shell exits:

```bash
trap 'rm -rf "$work"' EXIT
```

`EXIT` is a pseudo-signal meaning "whenever this shell terminates" — falling off
the end, an explicit `exit`, or `set -e` aborting.

Register it **immediately after** creating the thing it cleans up:

```bash
work=$(mktemp -d /srv/scratch/build-XXXXXX)
trap 'rm -rf "$work"' EXIT
```

Any gap between those two lines is a window where the directory exists and
nothing is responsible for it.

</details>

<details>
<summary>Hint 2 — what EXIT covers, and what it does not</summary>

Worth testing rather than assuming:

```
$ cat > /tmp/t.sh <<'S'
#!/bin/bash
trap 'echo CLEANED' EXIT
sleep 30
S
$ chmod +x /tmp/t.sh
$ /tmp/t.sh & sleep 0.5; kill -TERM %1; wait
CLEANED
```

bash runs the `EXIT` trap when it terminates on `SIGINT` or `SIGTERM` too, so
`trap ... EXIT` alone covers all three paths this exercise asks about. Naming
signals explicitly is only needed when you want *different* behaviour for them:

```bash
trap 'echo "interrupted, cleaning up" >&2' INT TERM
trap cleanup EXIT
```

**`SIGKILL` cannot be trapped.** Nothing runs after `kill -9`, by design. Any
scratch space that matters therefore needs a reaper — a `systemd-tmpfiles` rule
or a periodic job — as well as a trap. A trap handles the cases you can observe;
it cannot handle the case where the kernel stops scheduling you.

</details>

<details>
<summary>Hint 3 — a trap is a string, and it is expanded when it runs</summary>

```bash
trap 'rm -rf "$work"' EXIT      # single quotes: $work read at exit time
trap "rm -rf $work" EXIT        # double quotes: $work baked in NOW
```

Both work here, but the second is a hazard: if `$work` is empty at the moment
the trap is set, you have registered `rm -rf ` — or worse, if it later holds
something unexpected, you have registered whatever it held then.

Prefer a function. It is readable, testable, and there is no quoting to get
wrong:

```bash
cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT
```

Keep the handler short and make it safe to run twice — a trap can fire in
circumstances you did not plan for.

</details>

<details>
<summary>Solution</summary>

```bash
#!/bin/bash
set -euo pipefail

work=$(mktemp -d /srv/scratch/build-XXXXXX)

cleanup() {
  rm -rf "$work"
}
trap cleanup EXIT

for i in $(seq 1 200); do
  printf 'document %d\n' "$i" > "$work/doc-$i.txt"
done

if [ -e /srv/build/FAIL ]; then
  echo "build-index: corpus is corrupt" >&2
  exit 5
fi
sleep "${BUILD_SECONDS:-0}"

find "$work" -name 'doc-*.txt' | wc -l > /srv/build/index.out

echo "build-index: done"
```

And the backlog, which the fix does not touch:

```
$ rm -rf /srv/scratch/build-*
```

### Why this is a lesson at all

The cleanup line was not missing and it was not wrong. It was in a place that
only gets visited when nothing goes wrong — which describes the runs nobody
needs to worry about.

Three things worth keeping:

1. **Enumerate the exits, not just the happy path.** Success, error, signal,
   and un-trappable kill. A script has at least four ways to end and most are
   written as though it has one.

2. **Register cleanup at acquisition time.** Right after `mktemp`, right after
   the lock is taken, right after the connection is opened. The pattern
   generalises — `defer` in Go, `finally` in Python, RAII in C++ — and the
   reason is the same everywhere: the code that acquires knows what to release,
   and the code that exits does not.

3. **A trap is not a substitute for a reaper.** `SIGKILL`, a power cut and an
   OOM kill all skip it. Anything that accumulates on disk needs something
   periodic that does not depend on the producer behaving. This is
   `journal-eats-the-disk` from module 01 again, from the other side: bounded
   growth needs an actor whose job is bounding it.

The failure shape here is worth recognising on its own. Nothing alerted, nothing
errored, and the disk filled over five months — attributed, when it finally
broke, to whatever service happened to be writing at the time rather than to
the build job that had been leaking since March.

</details>
