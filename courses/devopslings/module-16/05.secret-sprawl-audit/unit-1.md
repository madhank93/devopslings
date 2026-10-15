---
title: "Find every secret the inventory service has left lying around"
---

## The situation

The inventory service is moving its secrets into OpenBao. Before anyone moves
anything, someone has to know where the secrets *are*. Every one that is
missed stays where it is, valid, after the migration is declared finished.

That someone is you. The estate is small:

| What | Where |
|---|---|
| the repo | <http://localhost:3000/devops/inventory> |
| its CI settings | the repo's **Settings → Actions** |
| its image | `127.0.0.1:5000/inventory/api:1.4` |
| its running container | `devopslings-inventory-api` |
| the registry it pulls from | <http://localhost:5000>, and the stack's `registry` container |

There are six secrets in it. Two of them are not anywhere you would see by
looking at the service as it is today.

There are also things that look like secrets and are not. An audit that lists
them sends someone off to rotate a value that was never sensitive. On a
real estate that means a change ticket, a deploy and an on-call page, for
nothing.

## Your objectives

Write every secret value you find into

```
scratch/secret-sprawl-audit/answers/secrets.txt
```

one per line, exactly as it appears where you found it. Just the value, not
`NAME=value`. Lines starting with `#` are ignored, so note where each one came
from. You will want that list when the rotation starts.

The forge login is `devops` / `devopslings`.

## What you're being graded on

That the file lists all six secrets in the estate, and nothing else. Each line
that is not a secret is reported back with the reason it is not one. Missing
secrets are reported as a count, along with the kinds of place you have already
found one in.

<details>
<summary>Hint 1 — the four places in plain view</summary>

- **The working tree.** Clone it and read it. `grep -rniE 'password|key|token|secret' .`
  is a start, not an audit. Read what it matches: an `.example` file and a
  test fixture both say what they are.
- **CI settings.** Forgejo has *secrets*, which no one can read back, and
  *variables*, which anyone with access to the settings can read. Someone put a
  token in the wrong one.

  ```
  curl -u devops:devopslings http://localhost:3000/api/v1/repos/devops/inventory/actions/variables/NOTIFY_WEBHOOK_TOKEN
  ```

- **The container.** `docker inspect devopslings-inventory-api` shows its
  environment. So does a `ps` in a debugging session, a crash dump and an
  orchestrator's API.

That is three. The fourth is in the list above too, and it is not in a file.

</details>

<details>
<summary>Hint 2 — what the estate used to contain</summary>

A deleted file is still in git. Every commit that ever existed is in every
clone:

```
git log --all --stat
git log -p --all -- .env
```

A deleted file is still in an image too. Each `RUN`, `COPY` and `ADD` is a
layer, and a later layer that deletes a file only *hides* it. Read the
`Dockerfile` in the repo, then:

```
docker history --no-trunc 127.0.0.1:5000/inventory/api:1.4
docker save 127.0.0.1:5000/inventory/api:1.4 -o api.tar
mkdir api && tar -xf api.tar -C api      # then untar each layer blob in turn
```

</details>

<details>
<summary>Hint 3 — what the tools wrote down</summary>

Someone once debugged an image pull by putting a token in the URL. URLs are
the one part of a request that every proxy, load balancer and server logs by
default.

```
docker logs devopslings-ci-stack-registry-1 2>&1 | grep -i token
```

The registry writes its access log to stdout, so `docker logs` is the access log.

</details>

<details>
<summary>Solution</summary>

```
# deploy/inventory.ini on main
Halyard-mq7-Vesper-22
# .env, added in one commit and deleted in the next
lgr_prod_4e1b9c07d2a85f36e0b7
# Actions variable NOTIFY_WEBHOOK_TOKEN
nwh_8c3f02d9b6a14e7f5d21
# DB_PASSWORD in the container's environment
Tarn-oxide-5590-quill
# /app/signing.key, deleted in a later image layer
isk_1f9a7d3e60b24c8895ce0d17
# access_token in a URL, in the registry's access log
rlt_c41e9b7a2f6d083e5b
```

And what stays off the list:

| Looks like | Is |
|---|---|
| `smtp_password = changeme` | the placeholder in an `.example` file |
| `lgr_test_0000…` | a test fixture, labelled as one |
| `ssh-ed25519 AAAA…` | a *public* key; the private half is the secret |
| the hex in `/app/assets.sig` | a sha256 of the signing key, which does not give you the key |
| `BUILD_SHA` | a commit id, public by design |

### Why the two hidden ones are the dangerous ones

The four in plain view will be found by whoever does the migration, because the
migration touches those places. The deleted `.env` and the deleted signing key
will not. Nobody migrates a file that does not exist. So when the migration is
done, those two are still valid, still in every clone and every pulled image,
and now nobody is looking for them.

Removing a secret from where it is *now* does nothing about where it has
*been*. The fix for both is rotation: issue a new value and revoke the old
one. Then the copy in history is worthless, and it no longer matters that you
cannot delete it. Rewriting git history or rebuilding the image is cleanup, and
it is worth doing. It is not the fix.

### Why the log one is the most common

Nobody decides to write a secret to a log. It happens because a token went into
a URL, a header got dumped at debug level, or an exception printed its
arguments. Logs are then shipped, indexed, retained for a year and readable by
far more people than the vault. The fix is upstream: credentials go in headers,
never in URLs, and the logging layer redacts known-sensitive fields before
anything leaves the process.

### Do this with a tool next time

Scanners such as `gitleaks` and `trufflehog` walk git history, and `trufflehog`
can scan images layer by layer. They find patterns: known prefixes and
high-entropy strings. That is exactly why they produce false positives like the
hash and the commit id above, and why their output is a starting list, not an
audit. Run one, then do what this lesson made you do by hand: decide what each
hit actually is.

</details>
