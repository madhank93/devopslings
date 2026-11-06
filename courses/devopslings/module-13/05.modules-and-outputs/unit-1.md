---
title: "the same three resources, pasted four times"
---

## The situation

`/root/envs/main.tf` is a hundred lines long. It is the same 25 lines four times:

```hcl
# ---- dev ----
resource "docker_network" "dev_net"     { name = "shop-dev" }
resource "docker_volume" "dev_data"     { name = "shop-dev-data" }
resource "docker_container" "dev_app"   { name = "shop-dev" ... }

# ---- test ----
resource "docker_network" "test_net"    { name = "shop-test" }
...
```

A fifth environment is on the way, and the quickest way to add it is
obvious: copy a block, change four names, apply. That is how the first four
got here. It is also how they drifted. One of the copies was hand-tuned
after it was pasted, and the others were not. Nobody remembers which, and
nothing in the file says it was on purpose.

A module turns the 25 lines into one definition with inputs. Each environment
becomes a call to it. A sixth environment is then one more key, not one more
paste.

The trap is in the move. Put the resources in a module and plan:

```
  # docker_container.dev_app will be destroyed
  # module.shop["dev"].docker_container.app will be created
  ...
Plan: 12 to add, 0 to change, 12 to destroy.
```

Nothing about the containers changed. Only their addresses did.

## Your objectives

1. Write one module under `modules/` with one network, one volume and one
   container, and call it once per environment.
2. Keep every environment's settings, including the one that differs.
3. Move the existing objects to their new addresses without recreating any
   of them.
4. Keep `tofu output -json endpoints` returning the same map. `deploy.sh`
   reads it.

## What you're being graded on

Every network, volume and container must be the original (same IDs), with
its data, restart policy and environment intact. The root configuration may
declare no `docker_*` resources. All module calls must use one source under
`modules/`, and that module must declare exactly one block of each type.
State must hold the four containers inside modules, the `endpoints` output
must match what it was before, and `tofu plan` must show no changes.

<details>
<summary>Hint 1 — find the difference first</summary>

```
grep -n restart main.tf
```

Anything that is not the same in all four copies becomes a module input.
Anything that is the same stays inside the module.

</details>

<details>
<summary>Hint 2 — a module is a directory</summary>

`modules/shop/main.tf` holds `variable` blocks for the inputs, the three
resources, and an `output` for anything the caller needs. Inside the module,
resources refer to each other as before: `docker_network.net.name`.

The root calls it with `for_each`, so each environment gets a key:

```hcl
module "shop" {
  source   = "./modules/shop"
  for_each = { dev = "unless-stopped", ... }

  env     = each.key
  restart = each.value
}
```

Run `tofu init` after adding a module. It has to install it, even when it is
a local directory.

</details>

<details>
<summary>Hint 3 — twelve moves</summary>

Each old address has a new one. A `moved` block records that they are the
same object:

```hcl
moved {
  from = docker_container.dev_app
  to   = module.shop["dev"].docker_container.app
}
```

Write one for each of the twelve resources, then plan. The plan should list
twelve moves and nothing to add, change or destroy. Apply it, because moves
reach the state only on apply.

</details>

<details>
<summary>Hint 4 — the output</summary>

The root can no longer name `docker_container.dev_app`. Values leave a module
only through its outputs, so give the module an `endpoint` output and build
the map from the module instances:

```hcl
value = { for env, m in module.shop : env => m.endpoint }
```

</details>

<details>
<summary>Solution</summary>

`modules/shop/main.tf`:

```hcl
terraform {
  required_providers {
    docker = { source = "kreuzwerker/docker" }
  }
}

variable "env" {
  type = string
}

variable "restart" {
  type    = string
  default = "unless-stopped"
}

resource "docker_network" "net" {
  name = "shop-${var.env}"
}

resource "docker_volume" "data" {
  name = "shop-${var.env}-data"
}

resource "docker_container" "app" {
  name    = "shop-${var.env}"
  image   = "busybox:1.37.0"
  restart = var.restart
  env     = ["SHOP_ENV=${var.env}"]
  command = ["sh", "-c", "echo shop $SHOP_ENV > /www/index.html; exec httpd -f -p 8080 -h /www"]
  networks_advanced {
    name = docker_network.net.name
  }
  volumes {
    volume_name    = docker_volume.data.name
    container_path = "/data"
  }
}

output "endpoint" {
  value = "http://${docker_container.app.name}:8080"
}
```

`main.tf`:

```hcl
module "shop" {
  source = "./modules/shop"
  for_each = {
    dev     = "unless-stopped"
    test    = "unless-stopped"
    staging = "unless-stopped"
    prod    = "always"
  }

  env     = each.key
  restart = each.value
}

moved {
  from = docker_network.dev_net
  to   = module.shop["dev"].docker_network.net
}
# ...and the same for dev_data and dev_app, and for test, staging and prod.
```

`outputs.tf`:

```hcl
output "endpoints" {
  value = { for env, m in module.shop : env => m.endpoint }
}
```

```
$ tofu init
$ tofu plan
  # docker_container.dev_app has moved to module.shop["dev"].docker_container.app
  ...
Plan: 0 to add, 0 to change, 0 to destroy.
$ tofu apply
```

### What the module bought

The difference between prod and the others is now one line in a map, where a
reviewer sees it, instead of one word in the third of four near-identical
blocks. The fifth environment is one more entry.

The `moved` blocks can stay for a while. Anyone still holding a state from
before the refactor gets the same moves on their next plan. Once every copy of
the state has been applied, they can go.

</details>
