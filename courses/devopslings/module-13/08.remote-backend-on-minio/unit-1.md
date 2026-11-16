---
title: "the state file is committed to git"
---

## The situation

`/root/platform` manages a network and two containers. Its state was a file on
one person's laptop. When a second person needed to apply, someone did the
obvious thing:

```
$ git log --oneline
4c1d2e0 Commit the state so everyone can apply
```

It works while one person applies at a time, and everyone pulls before they
start. The day two people apply from the same commit, each pushes a different
state, and git's merge conflict is now inside a JSON file that maps your code
to production. The state also holds every attribute of every resource, which
for real infrastructure means database passwords and private keys, now in git
history for good.

MinIO is running at `http://minio:9000` with a bucket called `tofu-state`.

## Your objectives

1. Configure the s3 backend: bucket `tofu-state`, key
   `platform/terraform.tfstate`, MinIO's endpoint with path-style addressing,
   and locking on.
2. Move the existing state there without losing any resource.
3. Take the state out of git, keep it out with `.gitignore`, and commit.
4. Keep credentials out of the code. The environment already has them.

## What you're being graded on

The containers and the network must be the original ones. No `.tf` file may
contain credentials. The grader takes a fresh copy of your **last commit**,
exactly what a colleague would clone, and runs `tofu init` there. It must
pick up the s3 backend at the right bucket and key, with locking on. The state
in MinIO must hold the resources, and a plan from that fresh copy must be
clean. The last commit must contain no state file, and `.gitignore` must
cover `terraform.tfstate`, its backups and `.terraform/`.

<details>
<summary>Hint 1 — the backend block</summary>

MinIO speaks the S3 API, but it is not AWS, so the s3 backend needs telling
where it is and that some AWS-only checks do not apply:

```hcl
terraform {
  backend "s3" {
    bucket = "tofu-state"
    key    = "platform/terraform.tfstate"
    region = "us-east-1"
    endpoints = {
      s3 = "http://minio:9000"
    }
    use_path_style              = true
    skip_credentials_validation = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
  }
}
```

Locking is one more line (lesson 03).

</details>

<details>
<summary>Hint 2 — migrate, not reconfigure</summary>

After changing the backend, `tofu init` asks what to do with the existing
state:

- `-migrate-state` copies the current state into the new backend.
- `-reconfigure` switches backend and ignores the old state. The new backend
  is empty, so the next plan wants to create everything that already exists.

Run `tofu plan` straight after the migration. "No changes" is the proof that
nothing was lost.

</details>

<details>
<summary>Hint 3 — getting it out of git</summary>

`.gitignore` only affects files git is not tracking yet. The state is tracked,
so it also needs `git rm --cached terraform.tfstate`, which untracks the file
and leaves it on disk.

That removes it from the next commit, not from history. Every secret that was
ever in a committed state should be treated as leaked and rotated. Rewriting
history is a separate job.

</details>

<details>
<summary>Solution</summary>

`backend.tf`: the block from Hint 1, plus `use_lockfile = true`.

```
$ tofu init -migrate-state
Do you want to copy existing state to the new backend? ... yes
Successfully configured the backend "s3"!
$ tofu plan
No changes. Your infrastructure matches the configuration.
$ printf '.terraform/\n*.tfstate\n*.tfstate.*\n' > .gitignore
$ git rm --cached terraform.tfstate
$ git add .gitignore backend.tf
$ git commit -m "Keep state in MinIO, not in git"
```

### What the backend gives you

State is now in one place everyone reads, and the lock means only one apply
writes it at a time. There is nothing to pull first, and nothing to merge.
Credentials come from the environment, so the code that describes the backend
is safe to commit, and each person or CI job brings their own access.

The local `terraform.tfstate` is still on disk, stale from now on. Delete it
once you trust the remote copy, so nobody points a tool at it by mistake.

</details>
