---
title: "The leaked token was rotated, and the attacker is still in"
---

## The situation

This is the leak from module 12. A deploy token was committed in
`.forgejo/workflows/deploy.yml`, and every build log printed it. Module 12 ended
with a sentence: *at a real provider there is a fifth command — revoking the old
token. There is no provider here to revoke it at.*

Now there is. `DEPLOY_TOKEN` is a real forge access token, belonging to a
service account called `deploy-bot`, with the scopes a deploy needs: read the
account, and push to the forge's container registry.

The team did what module 12 taught. They minted a second token, stored it as
the `DEPLOY_TOKEN` secret, took the literal out of the workflow, and the
pipeline is green. The ticket is closed.

A red team watched the repo while the token was public. They kept everything
they took, and left it for you:

```
scratch/what-a-leak-costs/red-team/
  NOTES.md          what they did with it, and when
  token             the token, as committed
  registry-bearer   what the registry gave them in exchange
```

## Your objectives

1. Nothing in `red-team/` works any more.
2. The deploy still works, as a service account rather than as `devops`.

Check objective 1 the way the attacker would: replay what they hold. A
dashboard that says "token revoked" is the defender's view. The attacker's
view is a `curl` that either succeeds or doesn't.

## Getting in

The forge is at <http://localhost:3000>, user `devops`, password `devopslings`.
That account is the forge admin. `deploy-bot`'s password is
`deploy-bot-vault-7731`; log in as it to see its tokens under
**Settings → Applications**.

`NOTES.md` has the replay commands.

## What you're being graded on

The check replays the red team's kit against the forge. The token must not log
in, with either header form. It must not be exchangeable for a registry
credential. And `registry-bearer` must not be able to open an image upload as
`deploy-bot`.

Then it starts a run of the deploy workflow itself, so it grades the
`DEPLOY_TOKEN` secret as it is now, not as it was at your last push. The run has
to go green, authenticated as an account that is not `devops`. Keep
`workflow_dispatch` in the workflow's `on:` list, because that is how the check
starts the run.

<details>
<summary>Hint 1 — which token leaked</summary>

`deploy-bot` has two tokens, and one of them is the deploy. Delete the wrong one
and production stops; delete the right one and the attacker stops. The forge
shows the last eight characters of each token. Compare them with
`red-team/token`.

Changing `deploy-bot`'s password does nothing to either token. A token is its
own credential. Making the repo private, or deleting it, does nothing either:
the token was never a credential *for the repo*. It is a credential for the
account.

</details>

<details>
<summary>Hint 2 — the token is dead and the check still fails</summary>

Read `NOTES.md` again. Seconds after taking the token, the attacker called
`GET /v2/token`. That is the normal container-registry login: you present a
credential and the registry gives you back a short-lived bearer token, which is
what `docker push` actually sends.

That bearer is signed by the forge and says *this is `deploy-bot`, with
`write:package`, until tomorrow*. When the registry checks it, it checks the
signature, the expiry and the account. It does not check whether the token you
traded for it still exists. That is why it is cheap to check, and it is why
revoking the token did not revoke it.

Replay it:

```
cd scratch/what-a-leak-costs/red-team
curl -i -X POST -H "Authorization: Bearer $(cat registry-bearer)" \
  http://localhost:3000/v2/deploy-bot/checkout/blobs/uploads/
```

`202 Accepted` means the attacker can still push an image as `deploy-bot`.

</details>

<details>
<summary>Hint 3 — what the bearer does depend on</summary>

It names an account. Try blocking `deploy-bot` from signing in, or deleting it,
and replay again. Then look at what happened to the deploy, because the
replacement token belongs to the same account.

The order is the one from module 12: **issue, store, revoke**. Issue the
replacement on a *new* identity first, store it, and only then remove the old
identity.

</details>

<details>
<summary>Solution</summary>

A new service account, a token for it, the secret pointed at it, and then the
old account deleted:

```
api=http://localhost:3000/api/v1

curl -u devops:devopslings -X POST $api/admin/users \
  -H 'Content-Type: application/json' \
  -d '{"username":"deploy-bot-2","email":"deploy-bot-2@example.invalid",
       "password":"<something long>","must_change_password":false}'

curl -u 'deploy-bot-2:<something long>' -X POST $api/users/deploy-bot-2/tokens \
  -H 'Content-Type: application/json' \
  -d '{"name":"deploy","scopes":["read:user","write:package"]}'
# -> "sha1": the new token

curl -u devops:devopslings -X PUT \
  $api/repos/devops/checkout/actions/secrets/DEPLOY_TOKEN \
  -H 'Content-Type: application/json' -d '{"data":"<the new token>"}'

curl -u devops:devopslings -X DELETE "$api/admin/users/deploy-bot?purge=true"
```

Then replay the kit. All three commands in `NOTES.md` should now be refused.

### Why rotation was not enough

Rotation makes the *new* credential work. Revocation makes the *old* one stop.
They are two separate acts, and a green pipeline only proves the first. That is
why the check takes the attacker's side: it is the only side from which
revocation can be seen.

### A credential is a tree, not a leaf

The leaked token was the root. While it was live, it could be exchanged for
other credentials, and each of those has its own lifetime and its own way of
dying. Here it was a registry bearer good for 24 hours. In a cloud account it is
a session token from an assumed role, good for an hour or twelve. In an OAuth
app it is a refresh token, good until someone revokes it. In a cluster it is a
service-account token minted by a pod the attacker started.

Revoking the root does not prune the branches. Revoking the *identity* does,
because every branch names it. That is what deleting `deploy-bot` did, and why
the replacement had to live on a different account first.

The other ways to kill those branches are blunter: rotate the key the forge
signs them with, which logs out every registry client on the forge, or wait for
them to expire. Waiting is a decision to let the attacker keep access for the
rest of that window.

### What the leak cost

Count it. One token in one commit cost:

- a service account, retired, and a new one with a new name
- every registry credential issued in the exposure window, invalidated
- an audit of every image pushed as `deploy-bot` while it was exposed, because
  `write:package` is exactly the scope that lets someone replace an image you
  will later deploy
- the access log read for everything else the token touched

Module 12's drill was *issue, store, revoke, scrub and audit*. This lesson is
the "revoke" step done for real, and the price of not doing it is everything in
that list, plus whatever the attacker pushed.

</details>
