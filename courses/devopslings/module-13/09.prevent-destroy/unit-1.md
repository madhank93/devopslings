---
title: "a one-line rename, and the plan deletes the database"
---

## The situation

`/root/db` runs a database container, `db`, and its data lives in a volume,
`db-data`, which holds 200 orders. There is also `web`, which holds nothing.

A colleague's branch renames the volume to match the docs:

```diff
 resource "docker_volume" "db_data" {
-  name = "db-data"
+  name = "pgdata"
 }
```

Plan it, and the one-line diff becomes this:

```
  # docker_volume.db_data must be replaced
-/+ resource "docker_volume" "db_data" {
      ~ name = "db-data" -> "pgdata" # forces replacement
Plan: 2 to add, 0 to change, 2 to destroy.
```

A Docker volume cannot be renamed, so OpenTofu destroys `db-data` and creates
an empty `pgdata`. The orders go with the old one. Last time a reviewer read
the plan and caught it. The process is now "read the plan carefully every
time", and that works until the day someone is tired.

Meanwhile a routine change is waiting: `web` moves to `RELEASE=2`. That plan
also replaces something, because changing a container's environment
recreates it. For `web` that is fine. Any guard you add has to tell the two
apart.

## Your objectives

1. Make every plan that would destroy `db-data` fail, without anyone having
   to read it.
2. Apply the routine change: `web` runs with `RELEASE=2`.
3. Keep `web` and `db` replaceable. Their data lives elsewhere, or nowhere.

## What you're being graded on

`db-data` must be the original volume with all 200 orders. `tofu plan` must
be clean and `web` must run with `RELEASE=2`.

Then the grader works on a copy of your directory and state, so nothing you
own is touched. A plan with `-replace=docker_volume.db_data` must fail
because of a destroy guard. The colleague's rename to `pgdata` must fail to
plan. Plans that replace `web` and `db` must still succeed.

<details>
<summary>Hint 1 — a lifecycle rule</summary>

Every resource can carry a `lifecycle` block. One of its arguments makes any
plan that destroys that resource an error, whatever the reason for the
destroy: a rename, a `-replace`, a removed block, or `tofu destroy`.

</details>

<details>
<summary>Hint 2 — which resource</summary>

Put it on what holds the data. The container can be recreated at any time and
mounts the same volume when it comes back. Guarding the container would block
every routine change to it, and people learn to remove guards that get in the
way.

`ignore_changes` looks related, but it does something else. It makes OpenTofu
ignore differences in the listed attributes. It does not stop a replace that
someone asks for, or a destroy.

</details>

<details>
<summary>Solution</summary>

```hcl
resource "docker_volume" "db_data" {
  name = "db-data"

  lifecycle {
    prevent_destroy = true
  }
}
```

and `RELEASE=2` on `web`, then:

```
$ tofu apply
  # docker_container.web must be replaced
Plan: 1 to add, 0 to change, 1 to destroy.
```

The colleague's branch now stops at plan:

```
$ tofu plan
│ Error: Resource instance cannot be destroyed
│
│   on main.tf line 1:
│    1: resource "docker_volume" "db_data" {
│
│ Resource instance docker_volume.db_data has prevent_destroy set, but the plan
│ calls for it to be destroyed.
```

### What it does not cover

`prevent_destroy` lives in the code. Delete the whole resource block and the
guard goes with it, and the next plan destroys the volume without
complaining. The same is true of anyone who edits the guard out to get their
change through. It stops the accident, not the decision.

For data that cannot come back, the guard is one layer. The others are
backups you have restored from at least once, and a policy check in CI that
fails any plan with a delete of a protected type, whatever the code says.

</details>
