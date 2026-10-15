---
title: "Put the secrets in git, encrypted, where CI can read them"
---

## The situation

The deploy needs three values: a database password, a payments API key and a
session secret. Right now they live in one file on one laptop:

```
scratch/sops-and-age/secrets.env
```

Whoever owns that laptop is the deploy process. When they are on holiday,
nothing ships.

The pipeline in `devops/checkout` is already written for the fix. It expects
`deploy/secrets.enc.env`, a file encrypted with **sops** using **age** keys,
and it decrypts it with the age identity in a repository secret called
`SOPS_AGE_KEY`. Neither exists yet, so the deploy is red.

## Your objectives

1. `deploy/secrets.enc.env` is on `main`, encrypted with sops to age keys.
2. The plaintext values appear in no commit, on any branch. Not even one that
   was reverted a minute later.
3. CI decrypts with **its own** key, not yours. You can still edit the file.

## Getting set up

```
git clone http://devops:devopslings@localhost:3000/devops/checkout.git
```

You need `sops` and `age`. If you don't have them, the sandbox does. From
`sandboxes/ci-stack`:

```
docker compose -p devopslings-ci-stack cp ../../scratch/sops-and-age/secrets.env sops:/work/
docker compose -p devopslings-ci-stack exec sops sh
```

Inside that container you have `git`, `sops`, `age` and `age-keygen`, and the
forge is at `http://forge:3000`. Clone from there.

The forge is at <http://localhost:3000>, user `devops`, password `devopslings`.

## What you're being graded on

That none of the three plaintext values, and no age private key, appears in any
commit reachable from any ref. That `deploy/secrets.enc.env` on `main` is a
sops file whose values are all encrypted. Then the check starts a deploy run
itself. `scripts/deploy.sh` prints the public key of the identity CI decrypted
with, and a fingerprint of each value. The check requires that key to be one of
the file's recipients, that the file has at least one other recipient, and that
the fingerprints match the values in `secrets.env`.

Leave `scripts/deploy.sh` alone; its output is what the check reads.

<details>
<summary>Hint 1 — keys, recipients and identities</summary>

An age key pair has two halves. `age-keygen -o me.txt` writes the private half,
the **identity**, which starts `AGE-SECRET-KEY-1`. `age-keygen -y me.txt`
prints the public half, the **recipient**, which starts `age1`.

You encrypt *to* recipients. Anyone holding a matching identity can decrypt.
A file can have several recipients, and each identity opens it alone.

So you want two key pairs: yours, and CI's. Encrypt to both recipients. Keep
your identity on your machine. Give CI's identity to CI.

</details>

<details>
<summary>Hint 2 — encrypting without the plaintext ever touching the repo</summary>

```
sops -e --age "$ME,$CI" \
  --filename-override deploy/secrets.enc.env \
  /path/outside/the/repo/secrets.env > deploy/secrets.enc.env
```

The input path is outside the working tree. Copy `secrets.env` into the repo to
encrypt it, and one `git add -A` puts the plaintext in history for good. The
check will find it there.

`--filename-override` tells sops which format to use (the `.env` suffix means
dotenv) and which `.sops.yaml` rule applies.

Then write a `.sops.yaml` that records both recipients:

```yaml
creation_rules:
  - path_regex: secrets\.enc\.env$
    age: age1you...,age1ci...
```

Without it, the next person who runs `sops -e` on a new file encrypts it to
whatever they pass on the command line, and CI is the one left out.

</details>

<details>
<summary>Hint 3 — giving CI its key</summary>

`SOPS_AGE_KEY` holds the *contents* of an identity file, not a path. Set it to
CI's `AGE-SECRET-KEY-1...` line at **Settings → Actions → Secrets**, or with
the API:

```
curl -u devops:devopslings -X PUT \
  http://localhost:3000/api/v1/repos/devops/checkout/actions/secrets/SOPS_AGE_KEY \
  -H 'Content-Type: application/json' -d "{\"data\":\"$(grep AGE-SECRET ci.txt)\"}"
```

Then don't keep a copy of `ci.txt` anywhere it doesn't need to be.

</details>

<details>
<summary>Solution</summary>

In the sops container (or anywhere with the tools):

```
age-keygen -o /work/me.txt
age-keygen -o /work/ci.txt
ME=$(age-keygen -y /work/me.txt)
CI=$(age-keygen -y /work/ci.txt)

git clone http://devops:devopslings@forge:3000/devops/checkout.git /work/c
cd /work/c
printf 'creation_rules:\n  - path_regex: secrets\\.enc\\.env$\n    age: %s,%s\n' "$ME" "$CI" > .sops.yaml
sops -e --filename-override deploy/secrets.enc.env /work/secrets.env > deploy/secrets.enc.env
git add .sops.yaml deploy/secrets.enc.env
git commit -m "encrypted deploy secrets" && git push
grep AGE-SECRET /work/ci.txt     # this goes into the SOPS_AGE_KEY secret
```

Look at what you committed. The variable names are in clear text, and the
values are `ENC[AES256_GCM,...]`. The `sops_age__list_*` lines are the data key,
encrypted once to each recipient. The `sops_mac` line is what stops someone
from swapping one encrypted value for another without the key.

### Why CI gets its own key

If CI decrypts with your key, your key is in the forge, in every runner that
has ever run the job, and in the memory of every job container. A leak from
any of those is a leak of *your* key. Then everything ever encrypted to you is
exposed, including files that have nothing to do with this repo.

With separate keys, a compromised runner costs CI's key. You remove one
recipient, re-encrypt with `sops updatekeys` and a new CI key, and rotate the
values that CI could read. Your key never moved.

The same idea applies to people. Every engineer who edits the file should be
their own recipient, so that when someone leaves you remove one line from
`.sops.yaml`, not reissue everyone's key.

### What encrypting in git does not give you

Removing a recipient stops them from decrypting *future* versions. Every old
commit is still encrypted to them, and they may already have the plaintext.
Removing someone's access to a sops file therefore always means rotating the
values too. Keys control who can read the file. They do nothing about what a
reader already knows.

And the variable names are public. `PAYMENTS_API_KEY` in clear text tells a
reader exactly what to look for. That is usually an acceptable trade for a
reviewable diff, but it is a trade.

</details>
