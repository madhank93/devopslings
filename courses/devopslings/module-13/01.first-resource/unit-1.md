---
title: "web runs because someone typed docker run"
---

## The situation

`web` is running. The only record of how it got there is `/root/web/run.sh`:

```
docker run -d --name web --restart unless-stopped \
  -e GREETING=hello -e PORT=8080 \
  busybox:1.37.0 \
  sh -c 'echo "$GREETING from web" > /www/index.html; exec httpd -f -p "$PORT" -h /www'
```

Someone runs it by hand after every rebuild. If they forget the restart
policy, nobody notices until the host reboots and `web` stays down.

The obvious move is to keep doing what works. Run the container, then write
the HCL afterwards to match it. Try that and the first `tofu apply` fails:

```
Error: Unable to create container: ... Conflict. The container name "/web" is already in use
```

OpenTofu does not adopt things it did not create. It only knows about what is
in its state, and right now its state is empty. To OpenTofu, `web` does not
exist, and the name is simply taken by a stranger.

## Your objectives

1. Write a `docker_container` resource in a `.tf` file in `/root/web` that
   describes the same container as `run.sh`. `versions.tf` already sets up the
   provider.
2. Get the running `web` to be the one OpenTofu created.
3. Make sure the whole cycle works: plan, apply, destroy, apply again.

## What you're being graded on

The grader checks that the running `web` is the container your state tracks,
and that it matches `run.sh`: image, restart policy, both environment
variables, and the page it serves. Then it runs `tofu destroy` and expects no
`web` and an empty state. Then `tofu apply` from nothing, the same checks
again, and a plan that shows no changes. It leaves `web` applied when it is
done.

<details>
<summary>Hint 1 — the commands</summary>

```
tofu init       # installs the provider (from the local mirror here)
tofu plan       # shows what apply would do; changes nothing
tofu apply      # does it, after you type yes
tofu destroy    # removes everything in state
tofu state list # what OpenTofu believes it manages
```

Read the plan every time. `+` creates, `-` destroys, `~` changes in place,
and `-/+` destroys and recreates.

</details>

<details>
<summary>Hint 2 — translating run.sh</summary>

Each flag maps to an argument on `docker_container`:

| `docker run` | `docker_container` |
|---|---|
| `--name web` | `name = "web"` |
| `--restart unless-stopped` | `restart = "unless-stopped"` |
| `-e K=V` | `env = ["K=V", ...]` |
| the image | `image = "busybox:1.37.0"` |
| everything after the image | `command = ["sh", "-c", "..."]` |

`$GREETING` inside an HCL string is fine as it is. HCL only interpolates
`${...}`, so a bare `$NAME` reaches the shell untouched.

</details>

<details>
<summary>Hint 3 — the name conflict</summary>

You have two ways out. Remove the hand-made container and let OpenTofu create
its own. Or import the existing one into state. This container holds nothing
worth keeping, so removing it is the simple answer.

Importing it also does not work as well as it sounds. The docker provider
cannot read a container's environment back from Docker, so after an import
the plan says `env` forces a replacement, even when your HCL matches exactly.
A later lesson imports things that do come back cleanly, and are worth
keeping.

</details>

<details>
<summary>Solution</summary>

`/root/web/main.tf`:

```hcl
resource "docker_container" "web" {
  name    = "web"
  image   = "busybox:1.37.0"
  restart = "unless-stopped"
  env     = ["GREETING=hello", "PORT=8080"]
  command = ["sh", "-c", "echo \"$GREETING from web\" > /www/index.html; exec httpd -f -p \"$PORT\" -h /www"]
}
```

```
$ docker rm -f web
$ tofu init
$ tofu apply
...
Apply complete! Resources: 1 added, 0 changed, 0 destroyed.
$ tofu plan
No changes. Your infrastructure matches the configuration.
```

Then prove it repeats: `tofu destroy`, `tofu apply`, `tofu plan`.

### What you have now

`run.sh` said how to start `web` once. `main.tf` says what `web` is. That is
the difference between a command and a description. Running the description
twice does nothing the second time, because OpenTofu compares it with what it
recorded and sees nothing to do. And `tofu plan` tells you what will happen
before it happens, which `run.sh` never could.

The cost is the state file. It is how OpenTofu knew, a moment ago, that the
hand-made `web` was not its own. The next lessons are about that file.

</details>
