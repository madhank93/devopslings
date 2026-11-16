---
title: "The state file is gone"
---

## The situation

`/ha/infra/main.tf` describes the reporting setup on pg1: two roles, the
`analytics` database and its `marts` schema. OpenTofu created all four. A
reporting job has since filled `marts.daily_sales` with a year of figures.

The state file, `terraform.tfstate`, was on a laptop that has been wiped.
There was no remote backend. The code is fine and every object is still on
pg1, but OpenTofu no longer knows they are the ones it made:

```
$ tofu plan
Plan: 4 to add, 0 to change, 0 to destroy.
```

## Your objectives

1. OpenTofu manages all four resources in `main.tf` again.
2. `tofu plan` reports no changes.
3. Nothing on pg1 is created, dropped or replaced to get there, and the
   reports in `marts.daily_sales` are untouched.

## What you're being graded on

- the two roles and the database are the same objects they were before the
  loss — the grader recorded their internal ids, which change when an object
  is recreated — and `daily_sales` still has its 365 rows;
- `main.tf` still declares all four resources, and all four are in the state;
- `tofu plan -detailed-exitcode` exits 0.

## Try it yourself

```
cd /ha/infra
tofu plan
tofu state list
```

<details>
<summary>Hint 1 — what the state is</summary>

The state is OpenTofu's map from each resource address in the code
(`postgresql_role.reporting`) to the real object it manages (the role named
`reporting`). Without it, every resource in the code looks new. The fix is to
rebuild that map, not to build the objects again.

</details>

<details>
<summary>Hint 2 — import</summary>

`tofu import <address> <id>` reads an existing object into the state under
that address. Since OpenTofu 1.5 you can also write `import` blocks in the
code, which `tofu plan` previews and `tofu apply` performs — reviewable, like
any other change.

Each resource type has its own id format. For this provider a role or a
database is its name, and a schema is `<database>.<schema>`.

</details>

<details>
<summary>Hint 3 — after the import</summary>

An imported object is read as it is, and the code may say something slightly
different about it. Then the plan shows an update *in place*: apply it. If a
plan ever says **must be replaced**, stop and read why: replacing a database
means dropping it.

</details>

<details>
<summary>Solution</summary>

`/ha/infra/imports.tf`:

```hcl
import {
  to = postgresql_role.reporting
  id = "reporting"
}

import {
  to = postgresql_role.analyst
  id = "analyst"
}

import {
  to = postgresql_database.analytics
  id = "analytics"
}

import {
  to = postgresql_schema.marts
  id = "analytics.marts"
}
```

```
tofu plan       # Plan: 4 to import, 0 to add, 1 to change, 0 to destroy.
tofu apply
tofu plan       # No changes.
```

### The tempting wrong answers

`tofu apply` straight away tries to create all four and fails at the first:
`role "reporting" already exists`. That one is safe because it is loud.

Dropping everything and applying "to get back in sync" works perfectly — the
plan is empty afterwards — and destroys a year of reports, because OpenTofu
manages the database and knows nothing about the tables inside it. Deleting
the resources from `main.tf` also gives an empty plan, and leaves four objects
that no code owns.

### Keeping it from happening

The state is the one file in an OpenTofu project that cannot be regenerated
from the code. Keep it in a remote backend with locking and versioning — an
S3-compatible bucket with object versioning turned on is the usual choice —
so a lost laptop, or a bad write, is one version restore away. And the state
holds every attribute OpenTofu reads, passwords included, so it is a secret
in its own right: back it up like one.

</details>
