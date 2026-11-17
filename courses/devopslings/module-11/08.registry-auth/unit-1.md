---
title: "CI can pull, production cannot"
---

## The situation

Until last week anyone who could reach the registry could pull from it. The
security review fixed that: `/etc/registry/config.json` now gives `shop/` to
CI and `finance/` to the finance team, and nothing to anyone else. CI kept
working, because CI logs in. Production never had to:

```console
$ /work/runtime/deploy.sh 127.0.0.1:15000/shop/web:1.4.0
Error: fetching manifest …: UNAUTHORIZED: authentication required
```

Two fixes are already being typed in the incident channel:

- put `"anonymousPolicy": ["read"]` back on `shop/**`;
- copy `/work/ci/docker/config.json` to the production nodes — "it works for CI".

## Your objectives

1. Create a registry account for production to use. Users are in
   `/etc/registry/htpasswd` (`htpasswd -B`, and mind what `-c` does); zot
   reloads it and `config.json` on save.
2. Give that account exactly what production needs: pulling `shop/web` and
   `shop/cart`. Nothing in `finance/`, no pushing, no deleting.
3. Log production in with it, so that `/work/runtime/deploy.sh` pulls both
   images using `/work/runtime/docker/config.json`.

## What you're being graded on

The grader reads the credentials from `/work/runtime/docker/config.json` and
checks them both ways. Allowed: pulling `shop/web:1.4.0` and `shop/cart:2.0.1`
through `deploy.sh`. Refused: pushing a new tag, overwriting an existing one,
deleting, reading `finance/ledger`, and reading a repository that no rule
names yet. It also checks that the shop images still need credentials, that
another team's account cannot read them, and that CI can still pull and push.

<details>
<summary>Hint 1 — how zot decides</summary>

For each request zot picks the **most specific** entry under
`accessControl.repositories` whose pattern matches the repository, then
checks, in order: the named `policies` for this user, `defaultPolicy` for any
logged-in user, `anonymousPolicy` for no user at all. `adminPolicy` applies
everywhere. The actions are `read`, `create` (push a new tag), `update`
(overwrite a tag) and `delete`.

</details>

<details>
<summary>Hint 2 — testing it yourself</summary>

```console
$ curl -s -o /dev/null -w '%{http_code}\n' -u NAME:PASS \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    http://127.0.0.1:15000/v2/finance/ledger/manifests/3.2.0
$ DOCKER_CONFIG=/work/runtime/docker crane copy \
    127.0.0.1:15000/shop/web:1.4.0 127.0.0.1:15000/shop/web:should-fail
```

</details>

<details>
<summary>Solution</summary>

```console
$ htpasswd -B /etc/registry/htpasswd robot-prod-pull
```

In `/etc/registry/config.json`, add a policy to the existing `shop/**` entry:

```json
"shop/**": {
  "policies": [
    { "users": ["ci"],              "actions": ["read", "create", "update"] },
    { "users": ["robot-prod-pull"], "actions": ["read"] }
  ],
  "defaultPolicy": []
}
```

```console
$ DOCKER_CONFIG=/work/runtime/docker crane auth login 127.0.0.1:15000 -u robot-prod-pull
$ /work/runtime/deploy.sh 127.0.0.1:15000/shop/web:1.4.0
pulled 127.0.0.1:15000/shop/web:1.4.0
```

### The part worth remembering

**Every consumer gets its own credential, sized to what it does.** CI pushes,
so CI's account can push. Production only pulls. A credential shared between
the two has the union of their rights and the exposure of both: it lives on
every node *and* every runner, and leaking it from either one lets an attacker
replace the images the other one runs.

**Check the refusals, not just the success.** "Production can pull now" is the
half anyone checks. The grader spends most of its time on the other half —
push, overwrite, delete, another team's repository — because a credential
with too much access works perfectly until it is stolen.

**Defaults are where scope leaks.** Two answers that pass the happy path:
`defaultPolicy: ["read"]` on `shop/**` gives the read to *every* account,
including finance's; a `read` policy on `**` gives production every repository
nobody has written a rule for, including next quarter's. Both read as "scoped"
in a review. Name the user, name the repositories.

**Names and expiry.** Harbor robot accounts are named `robot$project+name`, so
an audit log shows at once that a request was made by a machine and for
which project, and they can be created with an expiry. Kubernetes nodes
usually get the credential through an `imagePullSecret` per namespace, or
through the cloud's node identity (ECR, Artifact Registry) so there is no
long-lived password to steal at all — the better end state when the platform
offers it.

</details>
