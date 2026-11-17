---
title: "the policy that allows everything"
---

## The situation

`ingest`, a Lambda function in `/root/ingest`, moves uploads. It lists
`s3://uploads/incoming/`, reads each object, writes an upper-cased copy under
`processed/`, and deletes the original.

Its role, `ingest`, has one policy:

```json
{ "Effect": "Allow", "Action": "*", "Resource": "*" }
```

That is administrator access. If anyone gets code execution in this function,
through a dependency or a parsing bug, they get the whole account with it.

The usual first guess is to cut the policy down until something breaks, then
add back whatever broke. That finds what the function needs. It does not find
what is still allowed and never used, because nothing breaks when an extra
permission is left in.

## Your objectives

1. Keep `ingest` working: uploads under `incoming/` end up under
   `processed/`, upper-cased, and are removed from `incoming/`.
2. Make the role allow exactly what the function does, on the resources it
   does it to.
3. Leave no wildcard action (`*`, `s3:*`, `s3:Get*`) and no `Resource: "*"`.

`handler.py` is not yours to change.

## What you're being graded on

The grader reads every policy on the role, inline and attached. Any Allow
with a wildcard action, `Resource: "*"`, `NotAction` or `NotResource` fails.

It then uploads two files and runs `ingest`, and they must be moved.

Last, it deploys a probe function with the same role and tries six actions
next to the real ones: writing under `incoming/`, reading and deleting under
`processed/`, reading another bucket, reading the bucket's ACL, and listing
IAM users. All six must be denied.

<details>
<summary>Hint 1 — list what the function calls</summary>

Read `handler.py` call by call. Each boto3 call is one IAM action:
`list_objects_v2` is `s3:ListBucket`, `get_object` is `s3:GetObject`, and so
on. Write down the bucket and prefix each one touches.

</details>

<details>
<summary>Hint 2 — two kinds of S3 resource</summary>

`s3:ListBucket` acts on the bucket, `arn:aws:s3:::uploads`. The object
actions act on objects, `arn:aws:s3:::uploads/<key>`. One statement cannot
scope both kinds properly, so use one statement per resource.

</details>

<details>
<summary>Hint 3 — "works" is not the test</summary>

`s3:GetObject`, `s3:PutObject` and `s3:DeleteObject` on `uploads/*` make the
function work. They also let it overwrite anything under `incoming/`, and read
and delete everything under `processed/`, which the function never does. If
you want to check before the grader does, `aws iam simulate-principal-policy`
evaluates a role's policies for any action and resource you give it.

</details>

<details>
<summary>Solution</summary>

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": "s3:ListBucket",
      "Resource": "arn:aws:s3:::uploads" },
    { "Effect": "Allow", "Action": ["s3:GetObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::uploads/incoming/*" },
    { "Effect": "Allow", "Action": "s3:PutObject",
      "Resource": "arn:aws:s3:::uploads/processed/*" }
  ]
}
```

```
aws iam put-role-policy --role-name ingest --policy-name ingest \
  --policy-document file://policy.json
./invoke
aws iam simulate-principal-policy \
  --policy-source-arn arn:aws:iam::000000000000:role/ingest \
  --action-names s3:DeleteObject --resource-arns arn:aws:s3:::uploads/processed/x
```

### Why not Allow `*` with a Deny list

A Deny removes only what it lists. Every action not on the list, including
every action AWS adds next year, is still allowed. An allow list fails closed:
a permission you forgot shows up as an error you can see. A deny list fails
open, and nothing tells you.

On AWS, IAM Access Analyzer can generate a starting policy from the calls
CloudTrail recorded for a role. It is still a starting point. It only knows
what was called during the period it looked at.

</details>
