---
title: "one file for one customer, for fifteen minutes"
---

## The situation

Acme needs one file, `s3://invoices/2026-10/acme-4471.pdf`, and has no AWS
account. The `invoices` bucket is private. It also holds every other
customer's invoices and a `payroll/` prefix.

The first idea is to make the bucket public for an afternoon and send Acme
the plain URL. For that afternoon, every invoice and the payroll file can be
read by anyone who can guess a key, and S3 keys are easy to guess. Then
someone forgets to close it.

A **presigned URL** puts a signature in the query string. It is valid for
one request to one object, for as long as the signer chose, and it acts with
the signer's permissions. Nothing about the bucket changes.

Links to customers are signed by `share-bot`, an IAM user. Its key is the
`share` profile: `aws --profile share ...`. Its policy still covers last
month's invoices.

## Your objectives

1. Write a link for that one file to `/root/share/LINK`. It must be signed
   by `share-bot` and expire 15 minutes (900 seconds) after you make it.
2. Acme must be able to open it with no credentials.
3. `share-bot` can read what the link needs, but not `payroll/`, and cannot
   list the bucket.
4. Nothing in the bucket is public.

## What you're being graded on

Every object, and the bucket listing, must refuse anonymous requests, and no
public grant may remain. The link must be presigned by `share-bot`'s key, for
`/invoices/2026-10/acme-4471.pdf`, with `X-Amz-Expires=900`. It must return
the original file. Editing the link's expiry must break it.

`share-bot` must not be able to read `payroll/2026-10.csv` or list the
bucket. Last, the grader signs a `share-bot` link that lasts two seconds,
waits four, and checks that it fails.

<details>
<summary>Hint 1 — making the link</summary>

```
aws --profile share s3 presign s3://invoices/2026-10/acme-4471.pdf --expires-in 900
```

The default lifetime is an hour, which is not what the README says.

</details>

<details>
<summary>Hint 2 — the link is signed and still gives 403</summary>

Signing happens on your machine, with no call to S3, so it always succeeds,
even for an object the signer cannot read. The permission is checked when the
link is used, against the signer's policies. If `share-bot` cannot read the
object, neither can its link. Check with
`aws --profile share s3api head-object ...`.

</details>

<details>
<summary>Hint 3 — how much share-bot should be able to read</summary>

Anyone who has `share-bot`'s key, or who controls the tool that signs with
it, can sign a link to anything `share-bot` can read. Give it the invoices it
shares, not the bucket.

</details>

<details>
<summary>Solution</summary>

```
aws iam put-user-policy --user-name share-bot --policy-name share --policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:GetObject",
    "Resource":"arn:aws:s3:::invoices/2026-10/acme-*"}]}'
aws --profile share s3 presign s3://invoices/2026-10/acme-4471.pdf --expires-in 900 \
  > /root/share/LINK
curl -s -o /dev/null -w '%{http_code}\n' "$(cat /root/share/LINK)"
200
```

### What the link does and does not limit

The signature covers the method, the path and the expiry. Acme cannot change
the link to fetch another file or to last longer. It does not cover who
holds the link: anyone Acme forwards it to can use it until it expires. That
is why it is short and why `share-bot` is narrow.

On AWS, a link signed with temporary credentials (a role session) also stops
working when that session expires, even if `X-Amz-Expires` says later.
Long-lived links therefore need a long-lived key, which is one more reason to
keep them short.

</details>
