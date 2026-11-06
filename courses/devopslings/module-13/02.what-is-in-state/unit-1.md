---
title: "a rename in the code, and the plan wants to destroy production"
---

## The situation

`/root/app` manages two containers. The last commit is a tidy-up:

```
$ git show --stat HEAD
    Name the resource after the service; nightly-report moves to the platform repo
```

It renamed `docker_container.app` to `docker_container.api`, and it deleted
the `nightly-report` container from the code because the platform team owns it
now. Nothing about either container was meant to change. Now look at the plan:

```
$ tofu plan
  # docker_container.api will be created
  # docker_container.app will be destroyed
  # docker_container.legacy will be destroyed
Plan: 1 to add, 0 to change, 2 to destroy.
```

OpenTofu matches code to the real world through the state, by address. The
state says "`docker_container.app` is container `3f2a…`". The code no longer
has an `app`, so OpenTofu plans to destroy `3f2a…`. The code has an `api` that
the state has never heard of, so it plans a new one. As far as OpenTofu can
tell, you deleted one thing and wrote a new one.

The tempting fix is to open `terraform.tfstate`, change `"app"` to `"api"`,
and delete the `legacy` block. It is JSON. It would even work this time.

## Your objectives

1. Make the state record the api container under `docker_container.api`.
2. Make OpenTofu forget `nightly-report` without destroying it.
3. Leave the code as committed, and never open the state file in an editor.

## What you're being graded on

Both containers must be the exact ones that were running when you started
(same container IDs). The code must still declare only
`docker_container.api`. `tofu plan` must show no changes.

The state must also show signs that OpenTofu wrote it. Every write bumps the
state's `serial`, and every apply leaves the previous version in
`terraform.tfstate.backup`. A hand edit skips that bookkeeping, and the grader
looks for the gap.

<details>
<summary>Hint 1 — look inside first</summary>

```
tofu state list
tofu state show docker_container.app
jq '{serial, lineage, resources: [.resources[] | {type, name}]}' terraform.tfstate
```

`lineage` identifies this state across its whole life. `serial` counts its
writes. A remote backend refuses to overwrite a newer serial with an older
one. That is what stops two people from silently clobbering each other, and a
hand edit that forgets to bump it breaks the protection.

</details>

<details>
<summary>Hint 2 — the two commands</summary>

```
tofu state mv <old address> <new address>
tofu state rm <address>
```

`state mv` changes the address a real object is recorded under. `state rm`
makes OpenTofu forget an object, and the object itself is left alone. Neither
touches any container. Both write a timestamped backup next to the state.

</details>

<details>
<summary>Hint 3 — the same thing, in code</summary>

You can also say it in the configuration, where a reviewer sees it:

```hcl
moved {
  from = docker_container.app
  to   = docker_container.api
}

removed {
  from = docker_container.legacy
  lifecycle {
    destroy = false
  }
}
```

Then `tofu apply`. The plan shows "has moved to" and "will be removed from the
state", and destroys nothing. Both ways pass. The blocks are better on a team,
because every working copy and every CI run applies the same change, instead of
whoever ran `state mv` on their laptop.

Not `import`. Importing a docker container leaves its `env` unreadable, so the
plan wants to replace it anyway.

</details>

<details>
<summary>Solution</summary>

```
$ tofu state mv docker_container.app docker_container.api
Move "docker_container.app" to "docker_container.api"
Successfully moved 1 object(s).
$ tofu state rm docker_container.legacy
Removed docker_container.legacy
Successfully removed 1 resource instance(s).
$ tofu plan
No changes. Your infrastructure matches the configuration.
$ docker ps --format '{{.Names}}'
nightly-report
api
```

### What state is

State is the join table between your code and the world. It maps each address
in the code to the ID of a real object, and caches what that object looked like
at the last apply. It is how OpenTofu tells "change this one" from "make a new
one", and how it knew in lesson 01 that the hand-made `web` was not its own.

That is why a rename in the code is not a rename to OpenTofu. Moving code
around means moving the state's records with it, and `state mv`, `state rm`,
`import`, `moved` and `removed` are the tools for that. Each one keeps the
serial, the lineage and the backups honest, and an editor keeps none of them.

</details>
