---
title: "OpenBao is sealed and the keys are gone"
---

## The situation

OpenBao (`bao:8200`) holds the shop's secrets. It encrypts everything it
stores, and on every start it comes up **sealed**: it cannot decrypt its own
storage until enough unseal keys are entered to rebuild the key that does.

It restarted this morning. The unseal keys and root token from this year's
install were kept on one engineer's laptop, which has been wiped.
`/ha/bao/RUNBOOK.txt` says there is an escrow copy.

## Your objectives

1. Follow the runbook. Find out whether the sealed cluster can be opened.
2. Answer in `/ha/answers/lost-unseal-keys.txt` whether the secrets it holds
   can be read again.
3. Get the shop's database secret serving: `secret/shop/db` in OpenBao must
   hold a password that logs in to pg1 as `shop_app`, readable with the token
   in `/ha/app/bao-token`.
4. Make sure the next restart is a non-event.

## What you're being graded on

- your answer;
- OpenBao is unsealed, and the token in `/ha/app/bao-token` reads a
  `secret/shop/db` whose `password` logs in to pg1 as `shop_app`;
- the grader then restarts OpenBao and tries the keys in each file under
  `/ha/bao/escrow/`; it must unseal, and the secret must still read.

## Try it yourself

```
bao status
cat /ha/bao/RUNBOOK.txt
bao operator unseal          # prompts for a key
```

`BAO_ADDR` is already set in ops.

<details>
<summary>Hint 1 — the runbook's keys</summary>

Enter two of the escrowed keys. The first is accepted (`Unseal Progress
1/2`); the second fails with `message authentication failed`. A share is
only checked when enough of them are combined, and these combine into a key
that does not decrypt this storage. They are from the 2025 install. The
cluster was rebuilt since, and nobody updated the escrow.

</details>

<details>
<summary>Hint 2 — is there another way in?</summary>

No. That is the design: the root key exists only encrypted in storage, and
only a threshold of this cluster's shares can rebuild the key that decrypts
it. No admin override, no support ticket, no brute force. The secrets in that
storage are gone.

That is not the same as the *values* being gone. Every secret was issued by
something else first: the database password exists as a role on pg1, the
payment API key with the gateway. Recovering means going back to those
sources and issuing new ones.

</details>

<details>
<summary>Hint 3 — the rebuild</summary>

Discard the storage (`docker exec devopslings-ha-bao` lets you reach it) and
restart, then `bao operator init`. You get new unseal keys and a new root
token. Then: enable the `kv-v2` engine at `secret/`, set a new password on
pg1's `shop_app` role, store it, and give the app a token.

You cannot store the old password: Postgres keeps only a hash of it.

</details>

<details>
<summary>Solution</summary>

```
echo "old_secrets_recoverable: no" > /ha/answers/lost-unseal-keys.txt

docker exec devopslings-ha-bao sh -c 'rm -rf /openbao/file/*'
docker restart devopslings-ha-bao
bao operator init -key-shares=3 -key-threshold=2 -format=json > /root/init.json
jq -r '.unseal_keys_b64[]' /root/init.json > /ha/bao/escrow/unseal-keys.txt
bao operator unseal "$(jq -r '.unseal_keys_b64[0]' /root/init.json)"
bao operator unseal "$(jq -r '.unseal_keys_b64[1]' /root/init.json)"
export BAO_TOKEN=$(jq -r .root_token /root/init.json)

bao secrets enable -path=secret kv-v2
pw=$(head -c 18 /dev/urandom | base64 | tr -d '/+=')
psql -c "ALTER ROLE shop_app PASSWORD '$pw'"
bao kv put secret/shop/db username=shop_app password="$pw"

bao policy write shop-app - <<'HCL'
path "secret/data/shop/*" { capabilities = ["read"] }
HCL
bao token create -policy=shop-app -period=768h -field=token > /ha/app/bao-token
```

Then restart OpenBao yourself and unseal it from the escrow file, before the
grader does.

### What a rebuild really involves

Here it was one password. In production every secret in the store has to be
re-issued at its source: database passwords rotated, API keys revoked and
reissued with each provider, certificates re-signed, every dynamic secret
engine reconfigured. Every application that held a token needs a new one.
That list *is* your recovery runbook, and the time to write it is before you
need it.

### Keeping it from happening

- **Split the keys** among several people (`-key-shares=5 -key-threshold=3`
  is common), each kept somewhere different, so no single laptop holds a
  threshold.
- **Test the escrow** after every init or rekey. This incident was an escrow
  copy that had been stale for a year and nobody knew.
- **Auto-unseal** with a key management service moves the problem rather
  than removing it: the KMS key becomes the thing you cannot lose. The
  recovery keys it gives you cannot unseal, only authorise operations.
- **Back up the storage too.** An OpenBao snapshot is useless without the
  keys, and the keys are useless without the storage — they are two halves,
  and both need a copy.

</details>
