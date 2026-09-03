---
title: "a change reached main without review"
---

## The situation

`main` is protected. The rule requires one approving review and blocks on a
rejected one. It was added after the last incident, everyone agreed to it, and
it is still there.

The most recent commit on `main` is this:

```
hotfix: skip the range check, prices were rejecting
```

It is not attached to a pull request. Nobody approved it, because there was
nothing to approve.

Open the rule at **Settings → Branches** and read all of it, not just the part
about reviews.

## Your objectives

1. Close the way onto `main` that does not pass through a pull request.
2. Keep the review requirement.
3. Make the pipeline a condition of merging rather than a decoration.

## What you're being graded on

That a direct `git push` to `main` is rejected by the forge — the grader tries
one. That some rule still requires at least one approving review. And that a
status check is required, naming a context this repository actually reports.

<details>
<summary>Hint 1 — a merge rule is not a push rule</summary>

"Required approvals" governs merging a pull request. Pushing a commit to the
branch is a different operation and it has its own switch further down the same
form: **Enable Push**, with an allowlist of who may do it.

The allowlist has one name on it — the account everybody uses. That is the whole
bypass. It was almost certainly added for a good reason at the time, and then
it stayed.

</details>

<details>
<summary>Hint 2 — the required check is named, and the name is not the job's</summary>

Turning on **Enable Status Check** does nothing until you say *which* check.
The forge matches the name it reports, which is the workflow, then the job,
then the event that triggered it:

```
ci / build (push)
```

Not `build`. A required context that nothing reports is not a stricter rule —
it is a branch where no pull request can ever merge, because the thing it is
waiting for will never arrive.

Read the real names off a commit rather than guessing:

```
curl -s -u devops:devopslings \
  http://127.0.0.1:3000/api/v1/repos/devops/checkout/commits/$(git rev-parse main)/statuses
```

</details>

<details>
<summary>Hint 3 — do not fix it by deleting the rule</summary>

Removing the protection rule does make the "unreviewed change" problem go away,
in the sense that nothing is claimed any more. The rule was imperfect, not
useless: the review requirement is the part that works.

</details>

<details>
<summary>Solution</summary>

Three edits to the one rule:

- **Enable Push**: off. With it off there is no allowlist to be on, and every
  change reaches `main` through a pull request.
- **Required approvals**: still 1.
- **Enable Status Check**: on, requiring `ci / build (push)`.

Through the API, which is what the reference solution does:

```json
{
  "enable_push": false,
  "enable_push_whitelist": false,
  "push_whitelist_usernames": [],
  "required_approvals": 1,
  "block_on_rejected_reviews": true,
  "enable_status_check": true,
  "status_check_contexts": ["ci / build (push)"],
  "apply_to_admins": true
}
```

### The part worth remembering

**A protection rule is a list of doors, and you have to close each one.** The
review requirement and the push allowlist are independent, and a rule can be
strict about the first while standing wide open on the second. The question to
ask of any such rule is not "does it require review" but "what are all the ways
a commit can arrive here", and then to check each one. Direct push is one.
Force-push is another. Deleting and recreating the branch is a third.

**The allowlist entry is the one that survives review**, because it is always
added for a reason that was real at the time: a release job that pushes a
version bump, a migration someone had to land at 2am. It is then permanent,
and it belongs to an account whose pushes nobody reads.

**Measured here, and worth knowing because the folklore says otherwise:** in
Forgejo 11, `apply_to_admins: false` does *not* give a repository admin a way
around the branch. With `enable_push: false`, an admin's direct push is refused
like anyone's — `Forgejo: Not allowed to push to protected branch main` — and
an admin cannot merge a pull request past a required approval either, which the
API refuses with `not allowed to merge [reason: Does not have enough
approvals]`. Do not assume the shape of a bypass from what the field is called.
Try the push.

**Which means there is no built-in emergency exit, and that is the point.**
Once the rule is closed properly, a genuine 3am emergency has nowhere to go —
so the escape hatch has to be built on purpose, and the choice is what it leaves
behind. The bad version is an admin turning the rule off, doing the thing, and
turning it back on: the forge records the config changes but not that the commit
was the reason, and the next person finds a branch that was unprotected for
eleven minutes with no explanation. The auditable version is a break-glass
account — a second user, added as a collaborator, alone on the push allowlist,
used for nothing else. It is not more secure than the admin; every push it makes
is attributable to it, and there is no ambiguity about whether the emergency
path was used. Pair it with an alert on any push from that account.

**A required context is a promise that something will report it.** Two
consequences. Rename a workflow or a job and every branch requiring the old name
silently stops being able to merge, so the context name is an interface. And
when a workflow triggers on both `push` and `pull_request`, a pull request head
carries *both* `ci / build (push)` and `ci / build (pull_request)` — verified
here — so either can be required; requiring a `(pull_request)` context on a
workflow that only runs `on: [push]` is the version of this that wedges the
repository.

</details>
