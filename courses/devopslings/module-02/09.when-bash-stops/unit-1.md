---
title: "four scripts, and which of them should not have been a script"
---

## The situation

Four scripts, all in production, all working. Read them:

```
/srv/verdict/case-1-rotate.sh        18 lines   nightly log rotation to S3
/srv/verdict/case-2-reconcile.sh     380 lines  monthly settlement reconciliation
/srv/verdict/case-3-deploy.sh        55 lines   release deploy, runs as root
/srv/verdict/case-4-healthcheck.sh   12 lines   container health check
```

"Rewrite it in a real language" and "it's only a shell script" are both
positions people hold about all four of these, and neither is a reason.

## Your objective

Fill in `/root/answers/verdict.md`. For each case:

- **verdict** — `shell` or `program`
- **because** — one token: `composition`, `datastructures`, `testing`,
  `dependencies`, `performance`, `concurrency`
- **cost** — one sentence on what that choice gives up

Then name the closest call and say why.

## What you're being graded on

The verdict **and** the reason, paired. Getting the verdict right for the wrong
reason fails, because the reason is the part that transfers — the next script
you meet will not be any of these four.

Every case also requires a stated cost. A choice with no downside is not an
engineering decision, and if you cannot name what you are giving up you have not
finished making it.

The grader does not judge *which* case you call the closest, only that you
commit to one and defend it.

<details>
<summary>Hint 1 — the question is not size</summary>

Line counts here are 18, 380, 55 and 12, and the verdicts do not follow that
order. Two of these want rewriting and they are not the two longest.

Ask instead:

- **What is it made of?** Glue between existing programs, or logic of its own?
- **What is it fighting?** Does it emulate something the shell does not have?
- **What happens when it is wrong?** And can you find out *before* it runs?
- **Where does it run?** What is guaranteed to exist there?

</details>

<details>
<summary>Hint 2 — cases 1 and 4, where shell is correct</summary>

**Case 1** is `find`, `xargs`, `gzip` and `aws` joined together. Every piece of
work is done by an existing program; the script's whole job is to connect them
and get the ordering right. Rewriting it means calling the same four tools
through a subprocess API with more ceremony and no new safety. Shell is a
language *for* composing programs, and this is that.

**Case 4** runs inside an image containing the app binary, busybox `sh`, and
nothing else. There is no package manager and no interpreter to add one with.
The decision was made by the runtime before anyone had an opinion about
elegance — this is what a genuine constraint looks like, as opposed to a
preference.

Note case 4 is short *and* correct, while case 1 is longer *and* correct, for
completely different reasons. That is why the token matters more than the
verdict.

</details>

<details>
<summary>Hint 3 — cases 2 and 3, where it stopped</summary>

**Case 2** keeps four associative arrays, parses JSON with `sed`, and does
currency arithmetic through `bc`. Look at what it is emulating: maps, records,
and decimal numbers. The shell has one type and it is *string*; everything else
is imitation, and money arithmetic through string-to-`bc` round trips is the
kind of imitation that produces a discrepancy nobody can reproduce.

**Case 3** is only 55 lines, which is exactly why it is the interesting one. It
has no unusual dependencies and it is not complex. It runs **as root, on every
host, and deletes directories**. `prune()` pipes `ls` into `tail` into `xargs
rm -rf`, and there is no way to exercise that without a real machine — every
function shells out, so there is nothing to call in a test.

The deciding question is not "is this too big for shell" but "can I be
confident this is right before it runs?" For a script that deletes things as
root, the answer needs to be yes.

</details>

<details>
<summary>Solution</summary>

```
case-1: verdict=shell   because=composition
case-2: verdict=program because=datastructures
case-3: verdict=program because=testing
case-4: verdict=shell   because=dependencies
```

And the costs, which are the part that makes it a decision:

- **case 1** — no types and no test harness; a change to the date arithmetic is
  only checked by running it against real storage.
- **case 2** — a build step, a runtime on the finance host, and fewer people
  who can read it during month-end close.
- **case 3** — more ceremony for 55 lines, and a deploy tool that now needs
  deploying itself.
- **case 4** — logic that cannot grow much before it is unreadable, with no way
  to unit test it inside an image this small.

**The closest call is case 3.** Fifty-five lines is small enough that rewriting
looks like over-engineering, and that same argument correctly leaves case 1
alone. What separates them is blast radius: `rotate.sh` copies files;
`deploy.sh` runs as root and deletes directories on every host. Size is not the
axis. What happens when it is wrong is.

### Why this is a lesson at all

This is the first `architect` exercise in the course, and it is worth being
explicit about what that tier means and what it does not.

There is no command that fixes anything here. The deliverable is a judgement,
and the grader checks two things it *can* check: that your decision and your
stated reason agree with each other, and that you named a cost. It cannot grade
your prose, and it does not pretend to — the `closest-call` answer is checked
for existence and substance, not for which case you chose.

That is the honest boundary of an automated rubric. It can reject an answer
that is unreasoned, incomplete, or right for a reason that will not generalise.
It cannot tell you that you thought about it well. The prose is for the person
who reads it after you.

Three things worth carrying:

1. **"Too long for a shell script" is not a criterion.** A 400-line pipeline of
   existing tools may be fine; a 40-line script that does arithmetic on money
   as root is not. Length correlates with the real reasons and is not one of
   them.

2. **The reason is what transfers.** You will not meet these four scripts
   again. You will constantly meet the questions — is this composition or
   logic, can I test it before it does damage, what is guaranteed to exist
   where it runs.

3. **Name the cost.** Every choice here has one, and the ones taken without
   naming it are the ones that get relitigated for years. "We rewrote it in Go"
   is a decision; "we rewrote it in Go and accepted that fewer people can fix it
   at 3am, so we wrote a runbook" is an engineering decision.

</details>
