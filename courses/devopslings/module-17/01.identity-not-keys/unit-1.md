---
title: "the access key in the repository"
---

## The situation

`/root/reports` deploys `reports`, a Lambda function on floci. It counts the
rows in `s3://reports-data/daily/summary.csv` and returns the identity it ran
as:

```
$ ./invoke
{"rows": 63, "ran_as": "arn:aws:iam::000000000000:user/reports-bot"}
```

It reads S3 with the access key of an IAM user, `reports-bot`. The key is
written in `config.py`, which is committed. `deploy.sh` also copies it into
the function's environment variables.

The function already has an execution role, `reports`. Lambda hands every
function its role's short-lived credentials, and they expire on their own.
The role is allowed nothing yet, so nobody has ever used it.

## Your objectives

1. Make `reports` authenticate as its execution role and nothing else. Its
   output must not change, apart from `ran_as`.
2. Leave no long-lived key in `/root/reports` or in the function's
   environment.
3. Make sure nobody who has a copy of the leaked key can ever use it.

## What you're being graded on

The grader looks for an access key, or the leaked secret, in every file in
`/root/reports` and in the deployed package. It also checks that no code
passes credentials to boto3 itself and that the deployed function's
environment holds none.

It then calls `reports`. The function must count the rows correctly, and
`ran_as` must be an assumed-role session of `reports`.

Last, `reports-bot` must have no access keys left, active or inactive.

<details>
<summary>Hint 1 — where the role's credentials come from</summary>

Lambda puts the role's session credentials in the function's environment
(`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` and `AWS_SESSION_TOKEN`), and
boto3 reads them when it is given nothing else. A client made with
`boto3.client("s3")` already uses the role. The code only has to stop passing
a key of its own.

</details>

<details>
<summary>Hint 2 — the role is allowed nothing</summary>

Once the function stops signing with the key, it runs as `reports`, and every
call it makes is denied. Find what the function does: one action, on one
object. `aws iam put-role-policy` attaches an inline policy to the role.

</details>

<details>
<summary>Hint 3 — deleting it from the file is not enough</summary>

The key is in git history, in every clone and in every CI log that ever
printed the environment. You cannot recall those copies. You can make the key
worthless, and only IAM can do that. `aws iam list-access-keys --user-name
reports-bot` lists the user's keys.

Also check the environment of the function that is deployed now, not just
`deploy.sh`. `update-function-configuration` without `--environment` keeps
the variables the function already has.

</details>

<details>
<summary>Solution</summary>

Remove the key from the code and let boto3 find the role's credentials:

```python
import boto3

s3 = boto3.client("s3")
sts = boto3.client("sts")
```

Delete `config.py`, and remove the `ENV=` line and `--environment "$ENV"`
from `deploy.sh`. Setting `--environment "Variables={}"` on the update clears
the variables that are already deployed.

Grant the role the one call the function makes:

```
aws iam put-role-policy --role-name reports --policy-name read-summary \
  --policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Action":"s3:GetObject","Resource":"arn:aws:s3:::reports-data/daily/summary.csv"}]}'
./deploy.sh
./invoke
{"rows": 63, "ran_as": "arn:aws:sts::000000000000:assumed-role/reports/..."}
```

Then retire the leaked key:

```
aws iam list-access-keys --user-name reports-bot
aws iam delete-access-key --user-name reports-bot --access-key-id AKIA...
```

### Why delete, and not deactivate or rotate

Deactivating can be undone by anyone allowed `iam:UpdateAccessKey`, so the key
is not dead yet. Rotating, which means making a new key for the same user,
leaves a long-lived credential that now has to be stored somewhere, and
stored keys are how this started. Once the function runs on its role, nothing
needs `reports-bot` to have a key at all.

On AWS, check CloudTrail for what the key was used for before you delete it.
A leaked key is an incident, not just a code fix.

</details>
