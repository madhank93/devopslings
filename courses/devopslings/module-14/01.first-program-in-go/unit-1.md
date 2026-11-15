---
title: "web in Go, and the compiler has an opinion"
---

## The situation

`/root/hello/main.go` describes `web`, the same container module 13 started
with, as a Pulumi program in Go:

```
docker run -d --name web --restart unless-stopped \
  -e GREETING=hello -e PORT=8080 busybox:1.37.0 \
  sh -c 'echo "$GREETING from web" > /www/index.html; exec httpd -f -p "$PORT" -h /www'
```

It does not build. It has two mistakes, and they are caught in different
places. One is a value of the wrong type, and `go build` refuses it before
anything runs. The other is a value of the right type with the wrong content.
The compiler is happy with it. Only the provider can say it is wrong, and
only once Pulumi asks it.

That is the first thing to know about "infrastructure in a real language".
The compiler checks the program's types. It does not know which restart
policies Docker accepts.

`hcl/main.tf` has the type mistake from `main.go`, written in HCL. OpenTofu
has no compiler, but it does have a type check of its own.

## Your objectives

1. Make `main.go` build, and deploy it to the `dev` stack with `pulumi up`.
   `web` must run as the `docker run` line describes.
2. Prove the cycle repeats: `pulumi destroy` removes `web`, `pulumi up`
   brings it back, and `pulumi preview` afterwards shows no changes.
3. Fill in `answers.txt`: which field `go build` rejected, which field only
   `pulumi preview` rejected, and the first `tofu` command that rejects
   `hcl/main.tf`.

## What you're being graded on

The program must build. The running `web` must be the container the `dev`
stack tracks, and match the `docker run` line: image, restart policy, both
environment variables, and the page it serves. The preview must be clean.

Then the answers. After that, the grader runs `pulumi destroy` and expects no
`web` and an empty stack, then `pulumi up` from nothing, and the same checks
again. It leaves `web` deployed when it is done.

<details>
<summary>Hint 1 — the commands</summary>

```
go build ./...      # the compiler's opinion, in under a second
pulumi preview      # builds, runs the program, asks the provider; changes nothing
pulumi up           # does it, after you choose yes
pulumi destroy      # removes everything in the stack
pulumi stack        # which stack you are on, and what it holds
```

Every `pulumi` command builds and runs the program first, so a program that
does not compile fails all of them with the compiler's message.

</details>

<details>
<summary>Hint 2 — reading the compiler</summary>

`go build` names the file, the line and the field. Read the type it wanted.
In the Pulumi Go SDK, every input has its own type: `pulumi.String` for one
string, `pulumi.StringArray` for a list of them. An HCL list of strings is a
Go slice, and `pulumi.ToStringArray([]string{...})` turns one into the input
type.

</details>

<details>
<summary>Hint 3 — finding when OpenTofu notices</summary>

Try each command in turn and stop at the first that fails:

```
cd /root/hello/hcl
tofu init
tofu validate
```

`init` only installs providers. Anything after it reads the configuration
against the provider's schema.

</details>

<details>
<summary>Solution</summary>

The two fixes in `main.go`:

```go
Restart: pulumi.String("unless-stopped"),
Envs:    pulumi.ToStringArray([]string{"GREETING=hello", "PORT=8080"}),
```

`go build` rejects `Envs` with a `cannot use ... as pulumi.StringArrayInput`
error. Fix only that, and `pulumi preview` fails instead: the provider
expects `restart` to be one of `no`, `on-failure`, `always` or
`unless-stopped`, and `unless-stoped` is none of them.

```
$ pulumi up --yes
...
    + 1 created
$ pulumi destroy --yes && pulumi up --yes
$ pulumi preview --expect-no-changes
```

`answers.txt`:

```
compiler=Envs
preview=Restart
tofu=validate
```

### What the compiler bought

Less than it seems, and earlier. `tofu validate` catches the same type
mistake, before anything is created, without a compiler. What Go adds is
that the editor underlines it as you type, and that the check covers the
whole program, including your own functions. Neither tool catches a
misspelt restart policy until the provider looks at it. The later lessons
use the parts of Go that have no HCL equivalent at all.

</details>
