---
title: "the same pipeline, in the tool the enterprise actually runs"
---

## The situation

The rate service is built, tested and released by a Jenkins freestyle job
called `rate-legacy`: three shell steps, configured through a web form.

```
./build.sh
./tests.sh || true
./publish.sh
```

Somebody added the `|| true` eighteen months ago because a flaky test was
"blocking releases". It is still there, the flaky test was fixed a fortnight
later, and the job has been publishing whatever `build.sh` produced ever since,
green every time.

You will not find that in a pull request. The job's definition lives in
Jenkins' own configuration, so the change that broke the gate was made by
clicking Save.

There is also a `rate-pipeline` job, already pointed at `Jenkinsfile` on `main`.
It fails, because there is no Jenkinsfile.

## Your objectives

1. Write the `Jenkinsfile` that replaces the freestyle job: build, test,
   publish.
2. Make the test stage an actual gate — a failing suite must stop the release.
3. Leave one definition of how this service ships.

## What you're being graded on

That `Jenkinsfile` is on `main` and declares a `pipeline` with the three
stages. Then the grader pushes a healthy commit and requires `rate-pipeline` to
go green *and* to have published that commit. Then it breaks the rate
calculation, pushes, and requires the build to fail with that commit **not**
published. It also checks `rate-legacy` can no longer build.

<details>
<summary>Hint 1 — the shape of a Declarative Pipeline</summary>

```groovy
pipeline {
  agent any

  stages {
    stage('build') {
      steps {
        sh './build.sh'
      }
    }
  }
}
```

`agent any` says "run this anywhere you have an executor" — here that is the
controller itself, which is fine for a sandbox and is the thing you replace
with a real agent label at work.

`sh` runs a shell step and **fails the stage on a non-zero exit**, which is the
entire difference between this and the form you are replacing.

</details>

<details>
<summary>Hint 2 — you do not need an `if` to gate the publish</summary>

The instinct carried over from the freestyle job is to test the result and
decide whether to publish. Declarative Pipeline already does that: when a stage
fails, the stages after it do not run and the build is red.

So the gate is not something you add. It is something you get by *not* writing
`|| true`.

</details>

<details>
<summary>Hint 3 — two jobs that can both release is the original problem</summary>

Leaving `rate-legacy` enabled means the service still has two ways to ship, one
of which is the one you just proved was broken. Disable it or delete it —
disabling keeps the build history, which is usually what you want during a
migration.

Through the UI it is a button on the job page. Through the API:

```sh
curl -X POST http://localhost:8080/job/rate-legacy/disable -H "Jenkins-Crumb: ..."
```

Jenkins requires a CSRF crumb on POSTs, and the crumb is tied to the session
that asked for it, so fetch it with the same cookie jar you post with.

</details>

<details>
<summary>Solution</summary>

```groovy
pipeline {
  agent any

  stages {
    stage('build') {
      steps { sh './build.sh' }
    }

    stage('test') {
      steps { sh './tests.sh' }
    }

    stage('publish') {
      steps { sh './publish.sh' }
    }
  }
}
```

Plus disabling `rate-legacy`.

### The part worth remembering

**The reason to move a pipeline into the repository is not that YAML — or
Groovy — is nicer than a form.** It is that the definition becomes a thing with
a history, a diff, an author and a reviewer. `|| true` added through a web form
is invisible: no commit, no blame, no review, and the only record is an entry in
Jenkins' own audit log that nobody reads. The same three characters in a
Jenkinsfile arrive as a diff somebody has to approve. Pipeline-as-code is a
governance change wearing a syntax change.

**A stage is a gate because failure propagates, not because you checked.**
Declarative Pipeline stops at the first failing stage. So the gate is the
*absence* of error suppression, and every mechanism that suppresses it —
`|| true`, `catchError`, `sh(returnStatus: true)` without acting on the value,
`post { always { } }` used as if it were `success` — turns the gate back off.
When you audit a pipeline, read it for the places failure is caught rather than
the places it is checked.

**Jenkins and GitHub Actions differ in where the work runs, and it changes your
design.** `agent any` here means the controller, because this sandbox has no
agents; in a real Jenkins it means "any executor", and choosing between
`agent { label 'linux' }`, `agent { docker { image '…' } }` and `agent none`
with per-stage agents is a decision Actions makes for you with `runs-on`. The
transferable part is the same in both: a job runs somewhere specific, and the
somewhere is part of the pipeline's contract — a build that passes only on the
one machine with the right toolchain installed is a build you cannot reproduce.

**Migrations leave two ways to do everything, and the old one is the dangerous
one.** The freestyle job did not become safe when the Jenkinsfile appeared; it
became *unwatched*, which is worse, because the pipeline everyone believes in
is now the one nobody is looking at when someone triggers the other. Finishing
a migration means removing the old path, and "we'll delete it once we're
confident" is how both survive for years. Disable it the same day.

</details>
