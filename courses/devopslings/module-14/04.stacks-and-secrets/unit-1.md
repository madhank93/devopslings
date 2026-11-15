---
title: "prod needs a password, and the program only knows dev"
---

## The situation

`/root/notify` deploys `notify`, a mail relay, to one stack, `dev`. The SMTP
password comes from the shell of whoever runs `pulumi up`:

```go
// Export SMTP_PASSWORD before running pulumi up.
password := os.Getenv("SMTP_PASSWORD")
```

Now prod needs it too, on a different port with a different password. The
mail team's handoff is in `/root/handoff/dev.txt` and `prod.txt`.

The first guess is a second copy of the program, or an
`if ctx.Stack() == "prod"` with prod's values written into it. Either way the
program now knows every environment by name, and the passwords are in git.
The second guess is to keep the environment variable and put the right
password in it before each `up`. Then whatever was in that shell is what
gets deployed, and nothing records which password a stack is supposed to
have.

Pulumi has a place for this. Each stack has its own config file,
`Pulumi.<stack>.yaml`, and a value set with `--secret` is stored encrypted.

## Your objectives

1. Two stacks, `dev` and `prod`, from the one program. Each stack's port and
   password are stack config: `notify:port` and `notify:smtpPassword`.
2. Each stack runs one container, `notify-<stack name>`, with `PORT` and
   `SMTP_PASSWORD` in its environment, serving on that port.
3. Neither password in plaintext anywhere in the repository, in any commit,
   or in either stack's state.
4. Commit both stack config files.
5. Nothing in the program may depend on the stack being called `dev` or
   `prod`.

## What you're being graded on

Neither password may appear in the working tree or in any commit. Both
`Pulumi.dev.yaml` and `Pulumi.prod.yaml` must be committed with no pending
changes, each with `notify:port` and an encrypted (`secure:`)
`notify:smtpPassword`.

The program must build. `notify-dev` and `notify-prod` must run with their
own port and password and answer on that port. Neither stack's exported state
may contain its password in plaintext. The old `notify` container must be
gone.

Last, the grader makes a third stack, `check`, sets only its port and an
encrypted password, and runs `pulumi up`. `notify-check` must come up with
those values. It removes `check` again afterwards.

<details>
<summary>Hint 1 — stack config</summary>

```
pulumi stack init prod
pulumi config set -s prod notify:port 2525
pulumi config set -s prod --secret notify:smtpPassword '...'
```

The first writes `notify:port: "2525"` into `Pulumi.prod.yaml`. The second
writes `notify:smtpPassword: secure: ...`, encrypted with the stack's key.
That key comes from the passphrase in `PULUMI_CONFIG_PASSPHRASE`, which is
not in the repository. In the program, `config.New(ctx, "")` reads the
current stack's values, and `ctx.Stack()` is the stack's name.

</details>

<details>
<summary>Hint 2 — encrypted in the file is not the same as encrypted in state</summary>

`cfg.Require("smtpPassword")` decrypts the value and returns a plain Go
`string`. From then on Pulumi has no idea it was secret, and writes it into
state as it would any other input.

`cfg.RequireSecret("smtpPassword")` returns a `pulumi.StringOutput` marked
secret. Anything built from it with `pulumi.Sprintf` stays marked, all the
way into the container's `envs`, and state stores it encrypted. Check with
`pulumi stack export -s dev | grep <password>`.

</details>

<details>
<summary>Hint 3 — history</summary>

If a password reached a commit, removing it in the next commit does not
remove it: `git log -p` still shows it, and so does every clone. This
repository has never been pushed, so you can rewrite it. `git commit --amend`
for the last commit, or `git rebase -i` for an older one.

</details>

<details>
<summary>Solution</summary>

`main.go`:

```go
pulumi.Run(func(ctx *pulumi.Context) error {
	cfg := config.New(ctx, "")
	port := cfg.RequireInt("port")
	password := cfg.RequireSecret("smtpPassword")
	_, err := docker.NewContainer(ctx, "notify", &docker.ContainerArgs{
		Name:  pulumi.String("notify-" + ctx.Stack()),
		Image: pulumi.String("busybox:1.37.0"),
		Envs: pulumi.StringArray{
			pulumi.Sprintf("PORT=%d", port),
			pulumi.Sprintf("SMTP_PASSWORD=%s", password),
		},
		Command: pulumi.ToStringArray([]string{"sh", "-c",
			`echo notify > /www/index.html; exec httpd -f -p "$PORT" -h /www`}),
	})
	return err
})
```

```
$ pulumi stack init prod
$ for s in dev prod; do
    pulumi config set -s $s notify:port "$(sed -n 's/^port=//p' /root/handoff/$s.txt)"
    pulumi config set -s $s --secret notify:smtpPassword "$(sed -n 's/^smtp_password=//p' /root/handoff/$s.txt)"
    pulumi up -s $s --yes
  done
$ git add main.go Pulumi.dev.yaml Pulumi.prod.yaml
$ git commit -m "notify: dev and prod stacks, password as a secret"
```

The `dev` update renames the container from `notify` to `notify-dev`, so
Pulumi replaces it and the old one goes.

### Where the secret still is

In the container's environment, in plaintext, because that is where the
program puts it: `docker inspect notify-prod` shows it to anyone with access
to the Docker daemon. Pulumi's secrets keep a value out of the repository and
out of state. They say nothing about what the resource does with it. Getting
it out of the container's environment is a job for a secret store, which is
module 16.

</details>
