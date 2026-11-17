---
title: "pip installed someone else's acme-billing"
---

## The situation

The billing service's CI run last night logged this:

```console
$ cat /work/billing/ci/last-run.log
acme-billing 99.0.0 from impostor on the public index
```

`acme-billing` is ours. It has never been published anywhere but the internal
index, and its latest version there is 1.4.0. Nobody here released 99.0.0.
Someone outside the company saw the name — in a stack trace, a job posting, a
leaked `requirements.txt` — and published a package under it on the public
index with a version number higher than any we will ever reach.

```ini
# /work/billing/pip.conf
[global]
index-url = http://127.0.0.1:8081/simple/        # the public index
extra-index-url = http://127.0.0.1:3141/simple/  # ours
```

The first proposal in the incident channel is to rename the package to
something nobody could guess.

## Your objectives

1. Find out why pip chose 99.0.0, and from where. `pip download`, `pip install
   --dry-run --report -` and `curl` against both indexes are all available.
2. Change how CI resolves dependencies so that `acme-billing` — and anything
   internal it depends on — can only come from the internal index.
3. Keep `requirements.txt` asking for `acme-billing`. CI must still go green.

## What you're being graded on

The grader rebuilds both indexes, and before it does, the attacker gets
smarter: the public index now also carries `acme-ledger` 99.0.0 (acme-billing's
own internal dependency) and same-version copies of `acme-billing` 1.4.0 and
`acme-ledger` 2.1.0 with a wheel build tag. It then runs your `ci/install.sh`
in a fresh checkout and a clean environment, and inspects what landed in the
virtualenv. Both internal packages must have come from the internal index, and
the install must succeed.

<details>
<summary>Hint 1 — what pip does with two indexes</summary>

```console
$ cd /work/billing
$ PIP_CONFIG_FILE=pip.conf pip download --no-deps -d /tmp/x acme-billing -vv 2>&1 | grep -E 'Looking in|Found link'
```

pip treats `index-url` and every `extra-index-url` as one big pool of
candidate files. There is no priority between them, and "extra" does not mean
"fallback".

</details>

<details>
<summary>Hint 2 — what the internal index already has</summary>

```console
$ curl -s http://127.0.0.1:3141/simple/retrying-lite/
```

An internal index that mirrors the public packages you use is the usual
reason the internal index exists.

</details>

<details>
<summary>Solution</summary>

`/work/billing/pip.conf`:

```ini
[global]
index-url = http://127.0.0.1:3141/simple/
trusted-host = 127.0.0.1
```

```console
$ ci/install.sh
acme-billing 1.4.0 from internal
```

### The part worth remembering

**`--extra-index-url` is a merge, not a fallback.** pip collects every file for
a name from every index it is given and picks by version, then by wheel
preference. That is the whole of dependency confusion: an attacker who can
publish to *any* index in your list can win for *any* name in your tree. It is
the same for npm with scoped registries misconfigured, for Maven with several
`<repository>` entries, and for the virtual repository of an artifact manager
that merges internal and proxied-public.

**Version pins and renames don't fix it.** The grader's same-version impostor
shows why: `==1.4.0` constrains a number, and the attacker chooses numbers
too. A wheel's build tag, a different platform tag, or simply which index pip
reads first breaks the tie in ways you do not control. A new name is safe
until someone sees it.

**Fix the resolver, not the package.** The robust shapes are:

- **one index** that holds your packages and proxies or mirrors the public
  ones, and that *refuses to proxy names you own* (devpi, Artifactory and Nexus
  can all be set up this way);
- **hashes** for every file (`pip install --require-hashes`, `pip-compile
  --generate-hashes`, `uv lock`) — the next lesson's lockfile. On its own, with
  two indexes, this turns a compromise into a broken build, which is better
  but not fixed;
- **per-name index routing** where the tool supports it — npm scopes
  (`@acme:registry=`), uv's `index` with `explicit = true`, Maven's mirror
  rules — so internal names are never looked up publicly.

**Claim your names publicly as well.** Registering your internal names on the
public registry (as empty placeholders) closes the hole for every machine
whose configuration you do not control: a laptop with a stale `pip.conf`, a
contractor's CI.

</details>
