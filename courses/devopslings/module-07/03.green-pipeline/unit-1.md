---
title: "The pipeline is green and has never run a test"
---

## The situation

`devops/checkout` has a CI job, a test suite, and a README badge that says
passing. Every commit for the last month went green.

```
$ git log --oneline -1
a1f4c02 add the cart total

$ npm run tests
✔ an empty cart is zero
✔ one of one item
✖ three of the same item
  expected 28.5, got 9.5
```

The suite has been failing the whole time. CI has been green the whole time.
Both of those are true at once, and that is the thing to explain before you fix
anything.

## Your objectives

1. Work out why a green run proves nothing here.
2. Make CI actually run the suite. It will go red.
3. Make it green the honest way.

Objective 2 is the deliverable. Objective 3 is a two-character fix once the
build finally tells you what is wrong.

## Getting the repo

```
git clone http://devops:devopslings@localhost:3000/devops/checkout.git
```

The forge is at <http://localhost:3000>, user `devops`, password
`devopslings`. Runs are at
<http://localhost:3000/devops/checkout/actions>.

## What you're being graded on

That all three tests still exist, that nothing in the workflow can swallow a
failure, that the run for your commit is green — and that its log proves three
tests ran and three passed. A pipeline that skips the suite is green in exactly
the same way as one that passes it, so the check reads the numbers rather than
the colour.

<details>
<summary>Hint 1 — read the log of a run that "passed"</summary>

Open the last green run and look at what the test step actually printed.

Not "did it pass" — *what did it print*. A test runner that ran three tests
says so. This one printed nothing at all, which is not something a passing
test suite does.

</details>

<details>
<summary>Hint 2 — the two names that have to agree</summary>

```json
"scripts": { "tests": "node --test" }
```

```yaml
- run: npm run test --if-present
```

`test` and `tests` are different scripts. `--if-present` exists so that a
workflow shared across repos doesn't explode on the ones that have no test
script — and what it does here is turn "that script does not exist" into exit
code 0, with no output and no warning.

The flag is behaving exactly as documented. That is what makes it dangerous.

</details>

<details>
<summary>Hint 3 — expect red, and read it</summary>

When CI starts running the suite, the build breaks. That is the point: the red
is a month-old bug that the tests have been catching all along and nobody was
listening to.

Fix the code, not the test.

</details>

<details>
<summary>Solution</summary>

`package.json` — the script CI asks for:

```json
{
  "name": "checkout",
  "version": "1.0.0",
  "scripts": {
    "test": "node --test"
  }
}
```

`.forgejo/workflows/ci.yml` — no flag that can swallow a missing script:

```yaml
- run: npm test
```

Push that alone and the build goes red:

```
✖ three of the same item
  expected 28.5, got 9.5
# pass 2
# fail 1
```

`src/cart.js` never looked at `qty`:

```js
function cartTotal(items) {
  return items.reduce((sum, item) => sum + item.price * item.qty, 0);
}
```

```
# pass 3
# fail 0
```

### Why this is the most expensive kind of broken

A red build is an interruption. A build that is green for the wrong reason is
worse than no build at all, because it is *actively* telling you something
false, and everyone downstream believes it: reviewers merge on the strength of
the tick, releases go out on it, and the suite people wrote to protect the code
quietly stops being read.

The failure mode is silence. Nobody gets a notification saying "no tests ran
today".

### How this happens in real repositories

- **`--if-present` on a script that got renamed.** Exactly this lesson.
- **A test runner whose glob matches nothing.** `node --test "src/**/*.spec.js"`
  when the files are `*.test.js` exits 0 and reports `# tests 0`.
- **`continue-on-error: true`** added to get one flaky job past a deadline, and
  never taken out.
- **`|| true`** appended to a command for the same reason.
- **A job that never gets claimed** — the first-pipeline lesson's failure mode.
  No runner, no result, no red X.

They are all the same bug: the pipeline's exit code stopped depending on
whether the software works.

### The habit that catches it

Ask a pipeline to prove it did the work, not that it finished. Concretely:

- **Make it fail on purpose.** Break a test, push, and watch the build go red.
  If it doesn't, nothing else you believe about that pipeline is load-bearing.
  Do this when you set CI up, and again after anyone edits the workflow.
- **Read the numbers.** `# pass 3` is evidence; a green tick is a claim. This
  lesson's check reads the numbers for exactly that reason.
- **Assert the count where it matters.** For a suite that must not silently
  shrink, fail the build when the test count drops — `--test-reporter` output,
  a coverage floor, or a plain `grep -c`.

The general form: a check that cannot fail is not a check, and the only way to
know yours can is to have watched it do it.

</details>
