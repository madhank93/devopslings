---
title: "the role that trusts everyone"
---

## The situation

There are three accounts on floci:

| account | what is in it |
|---|---|
| `000000000000` production | `deploy`, a role CI uses to ship releases |
| `111111111111` tools | `ci`, the CI system's role, and `sandbox`, a role for experiments |
| `222222222222` a contractor | `contractor`, a user nobody here manages |

`deploy` exists for `arn:aws:iam::111111111111:role/ci` alone. In
`/root/deploy`, `./become ci`, `./become sandbox` and `./become contractor`
each try to assume it. Today all three succeed.

The first guess is to tighten `permissions.json`. It is the policy with the
releases bucket and the Lambda functions in it, so it looks like the one that
matters. It is not the one that decides who gets in.

## Your objectives

1. `tools:ci` can still assume `deploy`.
2. `tools:sandbox`, the contractor, and anyone else cannot.
3. Fill in `ANSWER`: which of `deploy`'s two policies decides who can become
   the role, and which decides what the role can do once someone has.

## What you're being graded on

The grader reads `deploy`'s trust policy. `Principal: "*"` narrowed by a
Condition fails, and so does naming a whole account. Then it tries to assume
`deploy` four ways:

- as a session of `tools:ci`, which must succeed;
- as a session of `tools:sandbox`, as the tools account's `runner` user, and
  as the contractor, which must all be refused.

`ANSWER` must name the right policy for each question.

<details>
<summary>Hint 1 — two policies, two questions</summary>

Every role has a trust policy (`aws iam get-role` shows it as
`AssumeRolePolicyDocument`) and permission policies. The trust policy is
evaluated when someone calls `sts:AssumeRole`. The permission policies are
evaluated on every call made with the session that results.

</details>

<details>
<summary>Hint 2 — both sides have to agree</summary>

Across accounts, the caller's own account must allow it to call
`sts:AssumeRole` on the role, and the role's trust policy must accept the
caller. `ci` and `sandbox` are both allowed to try. Only one side is yours,
and it has to tell them apart.

</details>

<details>
<summary>Hint 3 — naming the principal</summary>

A principal can be an account (`arn:aws:iam::111111111111:root`), which
trusts whatever that account's admins allow, or one role
(`arn:aws:iam::111111111111:role/ci`). The README asks for one role.
`aws iam update-assume-role-policy` replaces the trust policy.

</details>

<details>
<summary>Solution</summary>

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "AWS": "arn:aws:iam::111111111111:role/ci" },
    "Action": "sts:AssumeRole"
  }]
}
```

```
aws iam update-assume-role-policy --role-name deploy --policy-document file://trust.json
./become ci          # assumed-role/deploy/probe-session
./become sandbox     # AccessDenied
```

`ANSWER`:

```
who_can_assume=trust
what_it_can_do=permission
```

### Why the permission policy was the wrong place

With `Principal: "*"`, anyone in any AWS account whose own policies let them
call `sts:AssumeRole` could become `deploy`. Narrowing the permission policy
limits what they can do once they are in, but they still get in, and ship
releases as you.

### On real AWS

Two habits make this safer. Add an `sts:ExternalId` condition when a third
party assumes the role, so a confused deputy cannot be tricked into using
your role for someone else. Use IAM Access Analyzer, which flags any role a
principal outside your organisation can assume. floci does not evaluate trust
policy conditions, which is why this lesson grades the principal.

</details>
