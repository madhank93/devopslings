---
title: "two deploys at once, and the state forgot everything"
---

## The situation

`/root/shared` deploys `web` and `worker`. Its state lives in MinIO, so
everyone's checkout reads and writes the same state. On Tuesday two people ran
`./deploy.sh` two seconds apart. Both runs started normally. Now:

```
$ docker ps --format '{{.Names}}'
worker
web
$ tofu state list
$ ./deploy.sh
Error: Unable to create container: ... The container name "/web" is already in use
```

Both deploys read the state when it was empty, and both set out to create the
same two containers. One got there first. The other failed on the names, and
then wrote its own view of the world, which was empty, over the first one's
state. The containers are real and the state has forgotten them.

The first guess is to run it again until it works. That cannot work. Every
deploy reads the same empty state and fails on the same names. And even when
it does go through, nothing stops the next two deploys from overlapping the
same way.

## Your objectives

1. Get the state and the running containers to agree, so that `./deploy.sh`
   works and `tofu plan` shows no changes. The two containers hold nothing
   worth keeping.
2. Turn on state locking for the s3 backend. Keep the same bucket and key.
3. Make `deploy.sh` wait for a lock someone else holds, rather than fail.

## What you're being graded on

First, the state in `/root/shared` must match the running `web` and `worker`,
and a plan must be clean.

Then the grader makes two fresh copies of your directory, as two colleagues
would have. It adds a slow resource to each so their applies overlap for
certain. It destroys everything, then runs `./deploy.sh` in one copy and,
two seconds later, in the other. Both must succeed. Afterwards the state must
record exactly the containers that are running. It cleans up its slow resource
and leaves `web` and `worker` deployed.

<details>
<summary>Hint 1 — recovering</summary>

The state does not know about the containers, and they hold nothing. The
simplest way to make the two agree is to remove the containers and let a
deploy create them from code:

```
docker rm -f web worker
./deploy.sh
```

`tofu import` would also bring them back into state, but lesson 01 showed why
a docker container comes back from an import needing a replacement anyway.

</details>

<details>
<summary>Hint 2 — what a lock is here</summary>

Before an apply reads the state, it takes a lock. A second apply that finds
the lock taken does not read the state at all. The s3 backend can keep its
lock as an object next to the state file, `<key>.tflock`, created only if it
does not already exist. Look for `use_lockfile` in the s3 backend's settings.

Changing backend settings means running `tofu init` again. Since the state
stays in the same place, `tofu init -reconfigure` is enough.

</details>

<details>
<summary>Hint 3 — waiting instead of failing</summary>

With the lock on, the second deploy no longer corrupts anything. It just
fails:

```
Error: Error acquiring the state lock
```

That is safe, but deploy.sh should wait instead. `tofu apply` has a flag for
how long to keep trying for the lock. A retry loop around `tofu apply` also
passes, because the lock is what keeps it safe, but it is the same thing done
by hand.

</details>

<details>
<summary>Solution</summary>

```
$ docker rm -f web worker
```

In `versions.tf`, inside `backend "s3"`:

```hcl
    use_lockfile = true
```

In `deploy.sh`:

```sh
tofu apply -auto-approve -input=false -lock-timeout=5m
```

```
$ tofu init -reconfigure
$ ./deploy.sh
Apply complete! Resources: 2 added, 0 changed, 0 destroyed.
```

Run two deploys yourself, from two checkouts, to watch it work. The second
one prints `Acquiring state lock. This may take a few moments...` and sits
there until the first is done. Then it reads the state the first one wrote,
finds nothing to do, and exits clean.

### What the lock protects, and what it does not

The lock makes reading, planning and writing state one step that only one
apply can be inside at a time. Without it, "read state, change things, write
state" from two machines interleaves, and the last write wins.

It does not protect you from two people applying *different code*. The second
deploy waits, then applies its own version, and undoes the first one's change
if its checkout is older. The lock keeps the state honest. Keeping the code
consistent is a job for CI: one pipeline, applying one branch, one run at a
time.

</details>
