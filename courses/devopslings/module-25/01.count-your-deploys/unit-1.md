---
title: "How often does this repository actually ship?"
---

## The situation

The quarterly review wants checkout's deployment frequency, and wants it as
one number. Nobody has a dashboard. What exists is the repository: twelve
weeks of commits on `main`, and the tags the pipeline has been leaving behind
the whole time.

```
$ git clone http://devops:devopslings@localhost:3000/devops/checkout.git
$ cd checkout
$ git tag -l | head
deploy/production/403
deploy/production/406
...
```

There are three kinds of tag in there, and a few hundred commits. Someone on
the team has already said "we ship every day", and someone else has said "we
ship about thirty times a quarter". Both of them counted something.

## Your objectives

1. Work out how many times a change reached production in this history.
2. Write it in `scratch/count-your-deploys/answer.txt` (the path is printed
   when the lesson starts), together with what you counted as a deployment and
   what you looked at and left out.

## What you're being graded on

The number has to match the history exactly. Then the two sentences: a count
is only comparable with next quarter's if it says what it is a count of, so
`excluded=` has to account for every kind of thing in the repository that
looks like a deployment and is not one.

<details>
<summary>Hint 1 — read one of each</summary>

```
$ git tag -l | sed 's|/[0-9]*$||' | sort | uniq -c
$ git tag -n9 deploy/production/406
```

An annotated tag carries a message and a date of its own. The pipeline wrote
what happened into it.

</details>

<details>
<summary>Hint 2 — the production tags are not all deployments</summary>

```
$ git for-each-ref refs/tags/deploy/production --format='%(refname:short) %(contents)' | grep -v 'result: succeeded'
```

A deploy that failed its health check before any traffic moved left
production exactly as it was. It is a fact about the pipeline, and it belongs
in a different number.

</details>

<details>
<summary>Solution</summary>

```
$ for t in $(git tag -l 'deploy/production/*'); do
    git cat-file tag "$t" | grep -qx 'result: succeeded' && echo "$t"
  done | wc -l
28
```

```
deployments=28
counted=each deploy/production tag whose result is succeeded, hotfixes and retries included
excluded=deploy/staging tags (not production); production attempts that aborted
  before traffic moved; v1.N.0 release tags (a build, not a deploy); commits
```

Twenty-eight over twelve weeks is 2.3 a week. "Every day" was the staging
count; "about thirty" was every production tag, aborted ones included.

### The part worth remembering

**A deployment frequency is a definition before it is a number.** DORA's
definition is how often a change is deployed to production, and every word in
it excludes something that sits in the same repository:

- **Staging** is not production. A team that counts staging deploys reports
  its test cadence.
- **An aborted deploy** changed nothing. It counts towards the pipeline's
  reliability, not towards how often you ship.
- **A release tag or a build** is an artefact that exists. It ships when it is
  deployed, and some never are.
- **A commit** is not a deployment. Most deploys carry several, and the last
  few commits on `main` have not been deployed at all.

What it *includes* is just as deliberate: the hotfixes, and the Wednesday and
Thursday-afternoon retries, are production deploys. They are off the release
train, and they still changed what customers were running.

Write the definition next to the number. Next quarter somebody will change the
pipeline, and the only way to know whether frequency went up or the definition
moved is to have written the definition down.

</details>
