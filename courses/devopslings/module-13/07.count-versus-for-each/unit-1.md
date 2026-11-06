---
title: "retire billing, and the plan recreates search"
---

## The situation

`/root/svc` runs one container per service in a list:

```hcl
services = ["auth", "billing", "search"]
```

```hcl
resource "docker_container" "svc" {
  count = length(var.services)
  name  = "svc-${var.services[count.index]}"
  ...
}
```

Billing is being retired. Take it out of `terraform.tfvars` and plan:

```
  # docker_container.svc[1] must be replaced
-/+ resource "docker_container" "svc" {
      ~ name = "svc-billing" -> "svc-search" # forces replacement
  # docker_container.svc[2] will be destroyed
      - name = "svc-search"
Plan: 1 to add, 0 to change, 2 to destroy.
```

You removed one service, and the plan destroys two containers and creates
one. Search goes down, even though nothing about search changed.

It looks like a provider bug. It is not. With `count`, OpenTofu knows each
container by its position: `svc[0]`, `svc[1]`, `svc[2]`. Billing was `[1]`.
Take it out and search slides from `[2]` to `[1]`. Now `[1]` should be named
`svc-search` instead of `svc-billing`, which means a new container. And `[2]`
no longer exists, which means destroying the real search. OpenTofu is doing
exactly what the addresses say.

## Your objectives

1. Give each container an address that does not depend on its position.
2. Move the existing containers to their new addresses without recreating
   them.
3. Retire billing: only `svc-billing` is destroyed.

## What you're being graded on

`svc-auth` and `svc-search` must be the original containers (same IDs), and
`svc-billing` must be gone. The code must have one `docker_container` block,
not one per service and not `count`. The plan must be clean.

Then the grader plans three more edits to the list with `-var`, without
applying any of them: removing `auth` from the front, removing `search` from
the end, and adding `api` at the front. Each plan must touch exactly one
container, the one that was added or removed.

<details>
<summary>Hint 1 — keys instead of positions</summary>

`for_each` takes a set or a map and gives each instance the key as its
address:

```hcl
for_each = toset(var.services)
name     = "svc-${each.key}"
```

Now the addresses are `svc["auth"]`, `svc["billing"]` and `svc["search"]`.
Removing billing removes `svc["billing"]` and nothing else, wherever it was in
the list.

</details>

<details>
<summary>Hint 2 — the switch itself recreates everything</summary>

Change `count` to `for_each` and plan. It wants to destroy `svc[0]`, `[1]` and
`[2]` and create three new containers. Every address changed, and as lesson 02
showed, OpenTofu matches by address. Tell it which old address is which new
one, with `moved` blocks or `tofu state mv`, before you apply.

</details>

<details>
<summary>Hint 3 — do it in one step</summary>

Write the `for_each`, the `moved` blocks for auth and search, and the new
tfvars together, then plan. Billing's old address `svc[1]` has no new home,
so it is the only thing the plan destroys.

</details>

<details>
<summary>Solution</summary>

`main.tf`:

```hcl
resource "docker_container" "svc" {
  for_each = toset(var.services)

  name    = "svc-${each.key}"
  image   = "busybox:1.37.0"
  restart = "unless-stopped"
  command = ["sh", "-c", "echo ${each.key} > /www/index.html; exec httpd -f -p 8080 -h /www"]
}

moved {
  from = docker_container.svc[0]
  to   = docker_container.svc["auth"]
}

moved {
  from = docker_container.svc[2]
  to   = docker_container.svc["search"]
}
```

`terraform.tfvars`:

```hcl
services = ["auth", "search"]
```

```
$ tofu plan
  # docker_container.svc[0] has moved to docker_container.svc["auth"]
  # docker_container.svc[2] has moved to docker_container.svc["search"]
  # docker_container.svc[1] will be destroyed
Plan: 0 to add, 0 to change, 1 to destroy.
$ tofu apply
```

### When count is still right

`count` is fine when the instances are interchangeable, like three identical
workers where it does not matter which one goes. It is also the usual way to
switch one optional resource on or off: `count = var.enabled ? 1 : 0`.

Once each instance has an identity of its own (a name, a customer, a region),
use `for_each` keyed by that identity. Otherwise every edit to the list costs
you a careful read of the plan to see what the positions did this time.

</details>
