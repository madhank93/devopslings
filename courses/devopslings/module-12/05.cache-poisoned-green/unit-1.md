---
title: "CI is green and the dependency it tested is not the one in the lockfile"
---

## The situation

Installs were dominating the build, so somebody added a dependency cache.
It worked: ninety-second builds became twelve-second builds, and that was six
months ago.

```yaml
- uses: actions/cache@v4
  id: deps
  with:
    path: node_modules
    key: node-modules-${{ runner.os }}

- run: npm ci --offline
  if: steps.deps.outputs.cache-hit != 'true'
```

Last week a dependency upgrade went through CI green and took checkout down in
production. The upgrade was fine. The review was fine. The pipeline reported on
something that was not the code being merged.

Nothing here is exotic. Read the two steps again and ask what the second one
does on a day when the first one succeeds.

## Your objectives

Make the pipeline notice a dependency change, without giving up the cache that
makes builds fast.

The repository is currently on `pricing-rules` 1.0.0 and everything passes. To
see the problem, upgrade it to the vendored 2.0.0 — which raises the discount
cap and removes `legacyRound`, a function `src/pricing.js` calls — and watch CI
tell you it is fine.

## What you're being graded on

That the workflow still uses `actions/cache`, so "delete the cache step" is not
the answer. That the tip of `main` is green on the dependency its lockfile
names. And then the measurement: the grader pushes a commit that upgrades
`pricing-rules` to 2.0.0 and nothing else, and requires the pipeline to report
that as a failure. It force-pushes the repository back afterwards.

<details>
<summary>Hint 1 — reproduce it before you fix it</summary>

```
npm pkg set dependencies.pricing-rules=file:vendor/pricing-rules-2.0.0.tgz
npm install --offline          # updates package-lock.json
npm test                       # fails locally: legacyRound is not a function
git commit -am "upgrade pricing-rules" && git push
```

Locally it fails. In CI it passes. The difference is a directory that CI had
from before and your machine did not.

</details>

<details>
<summary>Hint 2 — what the key is for</summary>

A cache entry is stored under a key and restored by that key. So the key is a
claim: *anything with this key contains the same thing.*

```
key: node-modules-${{ runner.os }}
```

Read that as a sentence. It says every build on Linux, forever, may use the same
`node_modules` — no matter which dependencies the repository asks for.

What decides the correct contents of `node_modules`? Put *that* in the key.

</details>

<details>
<summary>Hint 3 — hashFiles</summary>

`hashFiles('some/path')` produces a hash of those files' contents, and it is
built for exactly this:

```
key: node-modules-${{ runner.os }}-${{ hashFiles('package-lock.json') }}
```

Change the lockfile and the key changes; a different key is a miss; a miss runs
the install. Nothing has to be cleared by hand, ever.

</details>

<details>
<summary>Solution</summary>

```yaml
- uses: actions/cache@v4
  id: deps
  with:
    path: node_modules
    key: node-modules-${{ runner.os }}-${{ hashFiles('package-lock.json') }}

- run: npm ci --offline
  if: steps.deps.outputs.cache-hit != 'true'
```

Now the same upgrade commit goes red, with the error it should have had the
first time:

```
TypeError: legacyRound is not a function
```

Builds that do not touch the lockfile still hit the cache and still take twelve
seconds. The cache did not need removing; its key needed to be true.

### The part worth remembering

**A cache key is a statement that two things are interchangeable.** Everything
that decides the cached content belongs in it, and nothing else does. For a
dependency directory that is the lockfile — not `package.json`, which can change
without changing a resolved version, and not the branch name, which changes
without changing anything. `hashFiles()` exists to put content into a key
instead of a label.

**A wrong key is worse than no cache.** No cache is slow. A wrong key is fast and
occasionally wrong, in a way that shows up as a green tick on a change that
breaks production — the failure is silent, delayed, and lands on whoever deployed
rather than whoever cached. "Clear the cache and re-run" is the ritual that grows
around it: it works every time, teaches nothing, and has to be repeated forever
because the key is still lying.

Two details that decide whether this pattern is safe:

- **`restore-keys` is a partial match, and it is fine here.** A fallback like
  `node-modules-${{ runner.os }}-` restores the newest near-miss when the exact
  key misses, which is useful — a mostly-correct `node_modules` makes the install
  faster. It stays safe because `cache-hit` is only `'true'` on an *exact* key
  match, so the install still runs and reconciles the difference. Measured on
  this runner: correct key plus that loose fallback still catches the upgrade.
  It becomes unsafe the moment the install is skipped on any restore rather than
  on an exact hit.
- **What you cache changes the risk.** Caching the package manager's *download*
  directory (`~/.npm`, `~/.m2`) is content-addressed and safe to reuse across
  lockfiles, and the install still runs every time. Caching the *installed tree*
  (`node_modules`, `vendor/`) is what allows skipping the install, which is where
  the speed and the entire hazard come from.

The same shape appears in every build system with a cache, and the question is
always the same one: if the answer would be different, is the key different?
Docker layer caching keys a `RUN` on the commands and files before it, which is
`layer-cache-and-size` in module 09; Bazel and Nix go furthest by hashing every
input by construction, so the question cannot be got wrong.

</details>
