---
title: "the rollback target was deleted on schedule"
---

## The situation

v1.8.0 of the API went out this morning with a bug in it. The decision to roll
back took five minutes. The rollback took one command, and the command failed:

```console
$ crane manifest 127.0.0.1:15000/shop/api:v1.7.0
MANIFEST_UNKNOWN: manifest unknown
```

v1.7.0 was released nine days ago. Nobody deleted it. The registry did, on
schedule, because of a policy someone added when CI builds started filling the
disk:

```json
"retention": {
  "policies": [{
    "repositories": ["**"],
    "deleteUntagged": true,
    "keepTags": [{ "mostRecentlyPushedCount": 8 }]
  }]
}
```

The team rebuilt v1.7.0 from its git tag to get production back. The rebuild
was not the same image — the base had moved and two dependencies had resolved
to newer patch versions — so they shipped a release nobody had tested to fix a
release nobody had tested enough. Production is stable now. The policy is
still in place.

## Your objectives

Rewrite the retention policy in `/etc/registry/config.json` so that:

1. The **three most recent releases** (tags like `v2.3.0`) always survive a
   retention pass, however many CI builds are pushed between them.
2. CI builds (`git-<sha>`) are still cleaned up: no more than **ten** of them
   left after a pass.

zot watches the file and reloads it when you save. Leave `storage.gc` and the
short `gcInterval` alone — they are how the grader gets a retention pass in
seconds instead of a day.

## What you're being graded on

The grader replays a release cycle through your policy: three releases, each
behind a run of ordinary CI builds, 24 builds in all. It waits for two retention
passes over `shop/api`, then tries the rollback — pulling each of the three
releases — and counts what is left of the CI builds. Turning retention off, or
into a dry run, keeps the releases by giving up the clean-up, and is refused.

<details>
<summary>Hint 1 — ask the registry why</summary>

zot logs every retention decision, with the rule that made it:

```console
$ docker logs devopslings-zot 2>&1 | grep '"module":"retention"' | grep v1.7.0
… "tag":"v1.7.0", … "decision":"delete","reason":"didn't meet any tag retention rule"
```

`mostRecentlyPushedCount: 8` counts *tags*, and counts all of them together. A
release is one tag among many CI tags, and every push to main moves it one
place further towards the edge. On a busy day, a release lasts a morning.

</details>

<details>
<summary>Hint 2 — one policy, two kinds of artefact</summary>

`keepTags` is a list of rules, and a tag survives if **any** rule keeps it. A
rule can be narrowed with `patterns`, a list of regular expressions matched
against the tag:

```json
"keepTags": [
  { "patterns": ["<what a release tag looks like>"], "mostRecentlyPushedCount": … },
  { "patterns": ["^git-"],                           "mostRecentlyPushedCount": … }
]
```

Releases and CI builds have different lifetimes for different reasons. Write
them as different rules.

</details>

<details>
<summary>Solution</summary>

```json
"retention": {
  "dryRun": false,
  "delay": "24h",
  "policies": [{
    "repositories": ["**"],
    "deleteUntagged": true,
    "keepTags": [
      { "patterns": ["^v[0-9]+\\.[0-9]+\\.[0-9]+$"], "mostRecentlyPushedCount": 10 },
      { "patterns": ["^git-"], "mostRecentlyPushedCount": 8 }
    ]
  }]
}
```

Watch it work:

```console
$ docker logs -f devopslings-zot 2>&1 | grep '"module":"retention"'
… "tag":"v1.8.0", … "decision":"keep","reason":"retained by mostRecentlyPushedCount:10 policy"
```

Ten releases rather than three: the requirement is a floor, and a release
image is a few hundred megabytes that will never be rebuilt identically. The
CI builds are the ones worth deleting.

### The part worth remembering

**A rollback is a pull.** It works only if the exact bytes you ran before are
still in the registry, and "we can rebuild it from the tag" is not the same
promise. A rebuild resolves the base image, the package manager and the
toolchain again, today — lesson 6 is that problem on its own. The time you
discover that is during an incident, which is when you can least afford a build
nobody has tested.

**Write retention around what an artefact is for.**

| Artefact | Why it exists | Keep it |
|---|---|---|
| Release | Rollback, audit, reproduction | By version, generously — the rollback window and then some |
| CI build | Promotion candidate, debugging | By count or age, short |
| What production runs now | Everything | Always, whatever its tag — `pulledWithin` keeps what is being pulled |

A single count across all of those treats a release like a branch build, and
the release loses, because there are always more branch builds.

**Retention is a delete with a schedule.** Before you turn one on, run it in
`dryRun` and read the decisions it *would* make — zot logs them exactly as
above, with `"dry-run":true`. Every "delete" line naming a release tag is this
incident, scheduled.

**Same idea, different names.** In Harbor this is a project's *Tag Retention*
rules — "retain the most recently pushed N artifacts" matching a tag pattern —
plus a separate garbage-collection schedule that frees the blobs afterwards.
ECR calls them lifecycle policies; Artifactory, cleanup policies. All of them
evaluate rules per tag, and all of them will delete a release if a rule written
for CI builds reaches it.

**A deleted manifest's blobs go later.** Retention removes tags and manifests.
Garbage collection removes the layers nothing references any more, after
`gcDelay`. Until then the disk usage does not move, which is why people turn
the policy up harder than they meant to.

</details>
