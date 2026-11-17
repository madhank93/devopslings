---
title: "a maintainer handed over a package, and the new one shipped a payload"
---

## The situation

The wallet service has one dependency, and it is pinned exactly:

```console
$ cat /work/wallet/requirements.txt
ps-tree==1.1.0
```

Last night's CI install logged this:

```console
$ cat /work/wallet/ci/last-run.log
event-stream==3.3.6
flatmap-stream==0.1.1
pip==25.1.1
ps-tree==1.1.0
```

Nobody here has heard of `flatmap-stream`. Its module says, in this replay,
`MALICIOUS: reads wallet keys`. In 2018 it said nothing so friendly: the
payload was encrypted, and decrypted only inside the build of one specific
wallet.

The service already does what most advice says: it pins its dependency, and it
installs from an internal mirror rather than the public index. The mirror is
filled by `ci/sync-mirror.sh` every night.

## Your objectives

Build three controls, each of which would have stopped this on its own:

1. **A lockfile.** CI's install must be pinned all the way down — every
   package, by hash — at the versions from before the incident, so that what
   is in the mirror cannot change what gets installed.
2. **A review gate.** `ci/sync-mirror.sh` must copy into the mirror only
   releases someone has approved, listed in `ci/approved.txt` as
   `name==version`, one per line. It must never delete from the mirror.
3. **The mirror, on its own.** CI's install must not need the public index.

Then answer `why_pinning_failed` in `/work/wallet/postmortem.txt`, and take
the incident's packages back out of the mirror.

## What you're being graded on

The grader replays the incident against each control with the others assumed
broken:

- **Lockfile.** The mirror is rebuilt holding everything the incident put
  there, *plus* a rebuilt `event-stream` 3.3.5 with the payload — the version
  you trust, re-published with a wheel build tag. The public index is taken
  offline. Your `ci/install.sh` runs in a fresh checkout: it must not install
  `flatmap-stream`. Installing the original 3.3.5 is a pass; refusing the
  install on a hash mismatch, with nothing installed, is also a pass.
- **Gate.** A new `event-stream` 3.3.8 and `flatmap-stream` 0.1.3 are
  published; your sync must not copy them. Then `left-pad==1.3.0` is added to
  `ci/approved.txt` and published, and `event-stream` is unpublished upstream
  entirely; after your sync, the mirror must have `left-pad` 1.3.0 and still
  have `event-stream` 3.3.5.
- **Write-up.** `why_pinning_failed` must say what the pin did not cover.

<details>
<summary>Hint 1 — where it came from</summary>

```console
$ cd /work/wallet && .venv/bin/pip show ps-tree event-stream
$ ls /srv/pypi/public/simple/*/
```

Read the `Requires` lines. Then ask which of those packages changed between
the last good build and last night's.

</details>

<details>
<summary>Hint 2 — a lockfile with pip</summary>

pip installs a hash-checked set from a requirements file in which every line
carries `--hash=sha256:…`; once one line has a hash, pip demands one for every
package in the tree, including the ones you did not name:

```text
ps-tree==1.1.0 --hash=sha256:…
event-stream==3.3.5 --hash=sha256:…
```

`sha256sum` on the mirror's files, or `pip hash`, gives you the values. Tools
that write this for you: `pip-compile --generate-hashes`, `uv pip compile
--generate-hashes`, and `pip lock`.

</details>

<details>
<summary>Solution</summary>

`requirements.txt`, the lockfile:

```text
ps-tree==1.1.0 --hash=sha256:<sha256 of ps_tree-1.1.0-py3-none-any.whl>
event-stream==3.3.5 --hash=sha256:<sha256 of event_stream-3.3.5-py3-none-any.whl>
```

`ci/approved.txt`:

```text
ps-tree==1.1.0
event-stream==3.3.4
event-stream==3.3.5
```

`ci/sync-mirror.sh`, the gate:

```sh
#!/bin/sh
set -eu
pub=/srv/pypi/public/simple
mirror=/srv/pypi/internal/simple
approved="$(dirname "$0")/approved.txt"
for f in "$pub"/*/*.whl; do
  [ -e "$f" ] || continue
  project=$(basename "$(dirname "$f")")
  version=$(basename "$f" | cut -d- -f2)
  grep -qxF "$project==$version" "$approved" || continue
  mkdir -p "$mirror/$project"
  cp -n "$f" "$mirror/$project/"
done
```

`postmortem.txt`:

```text
why_pinning_failed: the pin covered ps-tree only; flatmap-stream came in
transitively, through the event-stream>=3.3 range ps-tree itself declares.
```

and remove `event_stream-3.3.6-*` and `flatmap-stream/` from the mirror.

With the rebuilt 3.3.5 in the mirror, this lockfile makes the install fail:
pip picks the build-tagged file, and its hash does not match. That is a red
build instead of a compromised one. To stay green as well, a lock can name the
exact file — `event-stream @ http://127.0.0.1:3141/simple/event-stream/event_stream-3.3.5-py3-none-any.whl --hash=sha256:…`
— which is what npm's `package-lock.json` and pip's newer `pylock.toml` record.

### The part worth remembering

**You pin what you name; you run everything.** `ps-tree==1.1.0` never changed.
Its own requirement, `event-stream>=3.3,<4`, was a range, so a new release of
event-stream — from a new maintainer, with a new dependency — was inside it.
In 2018 most victims had event-stream several levels down, through packages
like `ps-tree`, and had never chosen it. Only a lockfile covers the
whole tree.

**A hash is the only pin that names bytes.** A version is a label the
publisher controls. Registries refuse to re-upload the same file name, but a
build tag, a new platform wheel, or a compromised mirror all produce new files
under an old version. The grader's rebuilt 3.3.5 beats a version-only lock
for exactly that reason.

**A mirror that copies everything is a cache, not a control.** The nightly sync
copied flatmap-stream in within hours. A mirror earns its keep when something
decides what enters it: an allowlist, a review on new packages and new
maintainers, or a quarantine — "no release younger than seven days" would have
cost little and buys time for malware to be found, which often happens within
days of publication. And it must not mirror deletions: in 2016 `left-pad` was
unpublished from npm and builds all over the world broke, except the ones that
had their own copy.

**Each layer covers the others' failure.** The lockfile alone failed closed
here; the gate alone would have let 3.3.6 in the day someone approved it
without reading it; the mirror alone was the incident's delivery mechanism.
Together, a malicious release has to get past a reviewer *and* a lockfile
change in code review *and* be in the mirror.

</details>
