---
title: "The single replica that reached production twice"
---

## The situation

`devops/deployments` holds one JSON file per service under `services/`, and
the deployer ships whatever is on main. Its incident log:

| | what happened |
|---|---|
| INC-2291 | `ledger` shipped with `replicas: 1`. A kernel-patch drain took its only pod; 11 minutes of failed payments. |
| INC-2417 | `checkout` shipped with `replicas: 1` in a config refactor. Same drain, 7 minutes. |

After each one, the review checklist in `CONTRIBUTING.md` got a line. After
the second, the same line again, in bold. This morning `services/search.json`
merged with `"replicas": 1`, through a review that ticked the box, and CI was
green, because CI checks that the JSON parses.

There is one service that is right to run one replica: `batch-reporter`
holds the nightly export's lock, and a second copy runs the export twice.
`policy/README.md` already describes how an exception should look. Nothing
reads it.

## Your objectives

1. Make the rule a check that fails the pipeline, on every push, to any branch.
2. Let a documented exception through, in the format `policy/README.md`
   describes, for any service that files one.
3. Make the exception's expiry real: an expired exception, one without a date,
   or one dated more than 90 days out does not count.
4. Fix `search`, and give `batch-reporter` its exception.

## Getting the repo

```
git clone http://devops:devopslings@localhost:3000/devops/deployments.git
```

The forge is at <http://localhost:3000>, user `devops`, password
`devopslings`. The runner's job image is `node:22-bookworm`, so a check can be
a Node script with no dependencies.

## What you're being graded on

Main has to be green, with `search` at two or more replicas and
`batch-reporter` at one under a live exception. Then the check pushes seven
branches off main, each adding one service, and reads the pipeline result of
each:

| the branch adds | the pipeline must |
|---|---|
| production, `replicas: 1` | fail |
| production, no `replicas` field | fail |
| production, `replicas: 1`, exception expiring in 30 days | pass |
| production, `replicas: 1`, exception that expired yesterday | fail |
| production, `replicas: 1`, exception with no `expires` | fail |
| production, `replicas: 1`, exception expiring in 400 days | fail |
| staging, `replicas: 1` | pass |

The branches are deleted afterwards.

<details>
<summary>Hint 1 — where the rule lives</summary>

In a file the pipeline runs, next to `ci/validate.js`, and a step in
`.forgejo/workflows/validate.yml` that runs it. The workflow already runs on
every push; leave it that way. A guardrail that only runs on main reviews
changes after they have shipped.

</details>

<details>
<summary>Hint 2 — the field that is not there</summary>

The deployer runs one replica when `replicas` is absent. `s.replicas < 2` is
`false` when `s.replicas` is `undefined`, so a check written that way waves
the most likely form of this mistake straight through.

</details>

<details>
<summary>Hint 3 — expiry is a comparison, not a field</summary>

An exception that has an `expires` field and a check that never compares it
with today is a permanent exception. Compare against the date the pipeline
runs, and refuse dates past the 90-day horizon, or the expiry is just a
formality filled in with `2099-12-31`.

</details>

<details>
<summary>Solution</summary>

`ci/policy.js`:

```js
const fs = require("node:fs");
const MAX_DAYS = 90;
const today = new Date().toISOString().slice(0, 10);
const horizon = new Date(Date.now() + MAX_DAYS * 864e5).toISOString().slice(0, 10);
const exceptions = JSON.parse(fs.readFileSync("policy/exceptions.json", "utf8"));
const problems = [];

function liveException(service, rule) {
  const e = exceptions.find((x) => x.service === service && x.rule === rule);
  if (!e || !e.reason) return false;
  if (!/^\d{4}-\d{2}-\d{2}$/.test(e.expires || "")) return false;
  return e.expires >= today && e.expires <= horizon;
}

for (const f of fs.readdirSync("services").filter((f) => f.endsWith(".json"))) {
  const s = JSON.parse(fs.readFileSync(`services/${f}`, "utf8"));
  if (s.environment !== "production") continue;
  const replicas = Number.isInteger(s.replicas) ? s.replicas : 1; // the deployer's default
  if (replicas < 2 && !liveException(s.service, "min-replicas")) {
    problems.push(`${s.service}: production with ${replicas} replica(s)`);
  }
}
if (problems.length) { problems.forEach((p) => console.error(`policy: ${p}`)); process.exit(1); }
console.log("policy: ok");
```

A step after validation in `.forgejo/workflows/validate.yml`:

```yaml
      - run: node ci/policy.js
```

`services/search.json` gets `"replicas": 2`, and `policy/exceptions.json`
gets batch-reporter's entry, with a reason and a date inside 90 days.

### Why the checklist failed twice

A checklist asks a person to notice an absence, in a diff, every time,
forever. It works until the day the reviewer is tired, or the change is a
600-line refactor, or the line is one of fourteen. Both incidents passed a
review that included the rule. A check runs on every change, takes no
attention, and cannot be ticked without being true.

Policy-as-code tools — Open Policy Agent with Conftest, Kyverno, Checkov —
are this script with a language for the rules and a library of common ones.
The parts that matter are the same at any scale: the rule runs before merge,
it fails closed on a missing field, and its exceptions are data, reviewed like
code.

### Why the exception needs an expiry

Every guardrail needs a way around it, or the first legitimate exception
gets the whole check deleted. The danger is the opposite: exceptions that
outlive their reason. `batch-reporter` will move to a leader-elected design
one day, and the exception that let it run one replica will still be there,
waiting for the next service to copy its config.

An expiry turns "we allowed this" into "we allowed this until we look again".
On the date, the build goes red, and someone either fixes the service or
writes down, again, why not. The 90-day cap keeps the date from becoming a
formality.

</details>
