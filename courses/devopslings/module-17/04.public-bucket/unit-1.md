---
title: "the bucket that is public by a route nobody checked"
---

## The situation

A customer export in the `exports` bucket can be downloaded by anyone who has
the URL:

```
$ ./anon customers/2026-10.csv
GET exports/customers/2026-10.csv anonymously: HTTP 200
```

The object's ACL says `public-read`. Everyone's first fix is to set it back
to `private` and close the ticket. Try it, then run `./anon` again.

An S3 object can be public by more than one route, and each is checked
separately:

- the **object's ACL**,
- the **bucket's ACL**, which can make the listing public,
- the **bucket policy**, which applies to every key it names, whatever their
  ACLs say.

On top of those, **Block Public Access** (BPA) is a set of four switches, per
bucket and per account, that make S3 refuse new public grants and ignore
existing ones. floci stores the switches but does not enforce them, so here
you have to close the routes yourself as well. That is good practice
anyway: a guard rail is not a reason to leave the hole behind it.

The application reads the bucket as an IAM user, `exports-app`, through its
own identity policy. `./app-read <key>` reads like it does.

## Your objectives

1. No object in `exports` can be downloaded or listed without credentials.
2. Remove every public grant: object ACLs, the bucket ACL, the bucket policy.
3. Turn on all four BPA settings for the bucket and for the account.
4. `exports-app` still reads every object, and every object is still there.

## What you're being graded on

The grader requests every object, and the bucket listing, with no
credentials. Each must be refused. It then reads every ACL and the bucket
policy for grants to `AllUsers`, `AuthenticatedUsers` or `Principal: "*"`,
checks BPA on the bucket and the account, and reads every object as
`exports-app`.

<details>
<summary>Hint 1 — finding the routes</summary>

```
aws s3api get-object-acl --bucket exports --key customers/2026-10.csv
aws s3api get-bucket-acl --bucket exports
aws s3api get-bucket-policy --bucket exports
```

Look for a grantee URI ending in `AllUsers`, and for `"Principal": "*"`.

</details>

<details>
<summary>Hint 2 — which objects</summary>

The ticket names one object. Only one object had a public ACL, but the bucket
policy covers `exports/*`, which is every object in the bucket. Check them
all, not just the one in the ticket.

</details>

<details>
<summary>Hint 3 — Block Public Access</summary>

```
aws s3api put-public-access-block --bucket exports \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3control put-public-access-block --account-id 000000000000 \
  --public-access-block-configuration ...the same...
```

The account-level setting covers buckets that do not exist yet.

</details>

<details>
<summary>Solution</summary>

```
for k in $(aws s3api list-objects-v2 --bucket exports --query 'Contents[].Key' --output text); do
  aws s3api put-object-acl --bucket exports --key "$k" --acl private
done
aws s3api put-bucket-acl --bucket exports --acl private
aws s3api delete-bucket-policy --bucket exports
ALL=BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-public-access-block --bucket exports --public-access-block-configuration "$ALL"
aws s3control put-public-access-block --account-id 000000000000 --public-access-block-configuration "$ALL"
```

`exports-app` keeps reading because its access comes from its own identity
policy, not from anything public.

### What not to do

A bucket policy that denies `Principal: "*"` does block anonymous reads. It
also blocks `exports-app`, because an explicit Deny beats every Allow,
including the application's own. Deleting the object is not making it
private either.

On AWS, new buckets have had BPA on by default since April 2023, and
`aws s3api put-bucket-ownership-controls` with `BucketOwnerEnforced` turns
ACLs off entirely. Both leave the bucket policy as the one place to audit.

</details>
