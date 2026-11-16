---
title: "the ledger volume is older than the code"
---

## The situation

Years ago someone created a network and a volume by hand:

```
$ docker network ls --filter name=payments
NETWORK ID     NAME           DRIVER    SCOPE
dfb93215b2ec   payments-net   bridge    local
$ docker volume ls --filter name=ledger
DRIVER    VOLUME NAME
local     ledger
```

`ledger` holds 500 settled transactions that exist nowhere else. The team
wants both managed in `/root/payments` like everything else.

The first guess is to write the HCL, delete the hand-made ones and let
OpenTofu create fresh copies. That is how lesson 01 ended, and it was fine
there, because `web` held nothing. Do it here and the transactions are gone.
In production, "destroy and recreate" also means an outage for everything
attached to the network.

## Your objectives

1. Write `docker_network.payments` and `docker_volume.ledger` so they describe
   the existing objects exactly.
2. Import both into state.
3. Finish with a plan that shows no changes.

## What you're being graded on

`payments-net` must be the original network (same ID). `ledger` must be the
original volume (same creation time) and still hold all 500 rows. The code
must declare both addresses, the state must hold them, and the plan must be
clean.

<details>
<summary>Hint 1 — import, then read the plan</summary>

An `import` block says "this address is that existing object":

```hcl
import {
  to = docker_volume.ledger
  id = "ledger"
}
```

A network is imported by name or ID, and a volume by name. `tofu plan` then
shows `Plan: 2 to import, ...`. Nothing is in state until you apply. Read the
rest of that line before you do. If it says anything other than
`0 to add, 0 to change, 0 to destroy`, the import comes with a replacement.

</details>

<details>
<summary>Hint 2 — why the plan wants to replace them</summary>

Import records the object as it really is. Then the plan compares it with your
code, like any other plan. Leave out a label or the gateway, and the code
asks for a network without them. For docker networks and volumes, almost
every attribute forces a new object, so the import is followed straight away
by `-/+ destroy and then create replacement`.

`docker network inspect payments-net` and `docker volume inspect ledger` show
every setting. Or let OpenTofu write a first draft for you:

```
tofu plan -generate-config-out=generated.tf
```

With the `import` blocks in place and no resource blocks, this writes
resource blocks from what it found. Review the draft, keep it, and plan again.

</details>

<details>
<summary>Hint 3 — a trap with volumes</summary>

Skip the import and just apply, and the volume appears to work. `docker volume
create` with an existing name returns the existing volume, so OpenTofu thinks
it created `ledger`. Then the next plan sees the labels differ and replaces
it. The network fails loudly instead (`network with name payments-net already
exists`). Fail loudly is the better of the two.

</details>

<details>
<summary>Solution</summary>

`/root/payments/main.tf`:

```hcl
import {
  to = docker_network.payments
  id = "payments-net"
}

import {
  to = docker_volume.ledger
  id = "ledger"
}

resource "docker_network" "payments" {
  name     = "payments-net"
  driver   = "bridge"
  internal = true

  ipam_config {
    subnet  = "10.42.0.0/24"
    gateway = "10.42.0.1"
  }

  labels {
    label = "team"
    value = "payments"
  }
  labels {
    label = "tier"
    value = "data"
  }
}

resource "docker_volume" "ledger" {
  name = "ledger"

  labels {
    label = "team"
    value = "payments"
  }
  labels {
    label = "backup"
    value = "nightly"
  }
}
```

```
$ tofu plan -out=import.plan
Plan: 2 to import, 0 to add, 0 to change, 0 to destroy.
$ tofu apply import.plan
$ tofu plan
No changes. Your infrastructure matches the configuration.
```

Saving the plan and applying that file means the apply does exactly what you
read, and nothing that changed in between.

### Import is a promise about the code

Import does not change anything. It writes one line into state: this address
is that object. The work is making the code describe the object so exactly
that the next plan has nothing to say. Once it is in, delete the `import`
blocks or leave them. After the first apply they do nothing.

</details>
