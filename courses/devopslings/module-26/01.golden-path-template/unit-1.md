---
title: "The template that makes another copy of orders"
---

## The situation

Every new service at this company starts the same way: someone copies
`devops/orders`, then spends three days finding every place it says `orders`.
The package name. The dashboard's uid, its title, and the `job=` label in each
query. The alert's selectors, its group, its `service:` label. Miss one and
the new service's dashboard quietly shows orders' traffic, or its alert pages
the orders team.

Last quarter someone made `devops/service-template`: a copy of orders, ticked
as a template in Forgejo, with a README listing the renames. Generate a
repository from it and push, and this is the first thing the new team sees:

```
✖ node ci/check-observability.js
observability: this is payments, and
  - package.json name is "orders"
  - dashboard uid is "orders"
  - dashboard query does not select job="payments": sum(rate(http_requests_total{job="orders"}[5m]))
  ...
```

`ci/check-observability.js` is the platform's own check, and it is right. The
template is a copy, and a README of steps is the same three days, written down.

## Your objectives

Make generating a service from `devops/service-template` the whole job. A
developer generates a repository, makes their first push, and it is green: the
tests ran, and the dashboard and alert are about their service. Nobody edits
anything in between.

## Getting started

```
git clone http://devops:devopslings@localhost:3000/devops/service-template.git
```

The forge is at <http://localhost:3000>, user `devops`, password
`devopslings`. **New Repository → Template** (or the **Use this template**
button on the template's page) generates a repository from it. So does the
API:

```
curl -u devops:devopslings -X POST http://localhost:3000/api/v1/repos/devops/service-template/generate \
  -H 'Content-Type: application/json' \
  -d '{"owner":"devops","name":"payments","git_content":true}'
```

Generating does not start a pipeline; the first push does.

## What you're being graded on

The check generates a fresh service from the template under a name it picks,
pushes one change to it, and requires:

- no file in the generated service still says `orders`, or a literal
  `$REPO_NAME`
- the dashboard's uid and title are the new service's, and all three queries
  select its `job`
- the alert selects only its `job` and carries its `service` label
- the pipeline for that first push is green, a test passed in it, and
  `ci/check-observability.js` passed in it

The generated repository is deleted afterwards.

<details>
<summary>Hint 1 — Forgejo can substitute, if you ask</summary>

A Forgejo template repository can contain a file, `.forgejo/template`, that
lists the files to expand when a repository is generated from it — one glob
per line. In those files, `${REPO_NAME}` becomes the new repository's name.
Variables in files the list does not name are copied as they are.

</details>

<details>
<summary>Hint 2 — what to list</summary>

Every file that names the service: `package.json`, both files under
`observability/`, and the README, because a README telling the new team to
rename orders is wrong the moment they read it. The workflow and the check
script name no service; they read it from `GITHUB_REPOSITORY` at run time,
which is the other way to get a name into a template.

</details>

<details>
<summary>Solution</summary>

Replace `orders` with `${REPO_NAME}` in the three files that name it, rewrite
the README, and add `.forgejo/template`:

```
package.json
README.md
observability/*
```

`observability/dashboard.json` in the template then reads:

```json
"uid": "${REPO_NAME}",
"title": "${REPO_NAME} — requests, errors, latency",
...
"expr": "sum(rate(http_requests_total{job=\"${REPO_NAME}\"}[5m]))"
```

Generate a repository called `payments`, push, and the check prints
`observability: ok for payments`.

### Why a README of steps is not a golden path

A golden path is the route where doing the right thing takes less effort than
doing anything else. Steps in a README fail that test in both directions: they
cost the three days they describe, and when someone skips one, nothing
notices. The dashboard that still selects `job="orders"` renders a perfectly
healthy graph of somebody else's service.

The template replaces the steps with a property: every generated service is
correct when it is created. That is why the check generates a fresh service
rather than reading the template: a template is only as good as what comes
out of it.

### What else belongs in the template

The same mechanism carries anything a new service needs on day one: an
ownership file, a runbook stub, the deploy configuration. The rule for what
goes in is what every service needs and gets wrong when copied by hand.
Anything the generated service will want to change is a parameter, not a
copy.

Tools like Backstage's software templates and cookiecutter do the same job
with more variables and a form in front. The idea is the one here: the
platform's opinion is executable, and the first commit is already green.

</details>
