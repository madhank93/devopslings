---
title: "Two teams that will not take the golden path"
---

## The situation

Five teams build software. Web, api and payments run their builds on the
golden path, the platform's shared pipeline. Data and mobile run their own,
and have for two years.

`/obs/platform/FEEDBACK.md` has what people said about it. Mobile blames the
approval gate. Data did not answer. The VP of Engineering wants both teams
added to `mandate:` in `/obs/platform/golden-path.yml` this sprint.

A mandate puts them on the path and leaves whatever drove them off it in
place, so they pay that cost on every build from then on. The pipeline data
can tell you what that cost is.

## Your objectives

1. Find, from the pipeline metrics, the golden-path stage that drives data and
   mobile off it.
2. Change the golden path so that it stops costing them that. Keep the
   approval gate, which is a SOC 2 control, and mandate nobody.
3. Write your finding to `/obs/answers/adoption.txt`:

   ```
   stage: <deps, test, approval or deploy>
   evidence: <the PromQL that shows it>
   ```

## Getting started

You work in the `box` container. The simulator,
`/obs/apps/gateway_exporter.py`, models how teams choose a pipeline: a team
uses the golden path when it is no slower for them than their own pipeline,
and otherwise tries it one build in twenty. It reads `golden-path.yml` every
second, so a change shows up in the metrics straight away. It is a model, and
the check refuses to run if it was edited.

```
promq 'sum by (team, pipeline) (rate(ci_pipeline_runs_total[1m]))'
```

Stage timings are in `ci_pipeline_stage_duration_seconds_sum` and `_count`,
by `team`, `pipeline` and `stage`.

## What you're being graded on

- `mandate:` is empty and the approval gate is still required.
- `stage:` names the stage that costs data and mobile the time.
- `evidence:` is a query on the stage-duration metrics that Prometheus runs
  and that returns data.
- Data and mobile run at least 90% of their builds on the golden path, and
  web, api and payments still do.

<details>
<summary>Hint 1 — average stage time</summary>

A sum divided by a count of the same labels is an average:

```
sum by (team, pipeline, stage) (rate(ci_pipeline_stage_duration_seconds_sum[5m]))
  / sum by (team, pipeline, stage) (rate(ci_pipeline_stage_duration_seconds_count[5m]))
```

Data and mobile try the golden path one build in twenty, so the golden
pipeline has their numbers too.

</details>

<details>
<summary>Hint 2 — compare a team against itself</summary>

Put data's golden-path stages next to data's own pipeline. Approval is 30
seconds. One stage is about twenty times longer on the golden path than it is
on their own pipeline. Now look at what `golden-path.yml` says about that
stage.

</details>

<details>
<summary>Solution</summary>

The deps stage: data's dependency install takes about 960 seconds fresh and
45 from a cache, mobile's 1140 and 50. Their own pipelines cache it. The
golden path installs fresh on every build.

```yaml
stages:
  deps:
    cache: true         # restore dependencies from a cache keyed on the lockfile
```

```
stage: deps
evidence: sum by (team, pipeline) (rate(ci_pipeline_stage_duration_seconds_sum{stage="deps",team=~"data|mobile"}[5m])) / sum by (team, pipeline) (rate(ci_pipeline_stage_duration_seconds_count{stage="deps",team=~"data|mobile"}[5m]))
```

Within a few seconds both teams' builds move to the golden path, and nobody
told them to.

### Why what teams say is not the answer

Mobile named the part of the golden path they notice: a person has to click.
Waiting for a person feels slow; a 19-minute install that runs while you do
something else does not register as the reason, but it is most of the
difference. Surveys say what is annoying. Stage timings say what costs time.

### Why the mandate is the wrong fix

A mandate moves the number on the adoption dashboard and nothing else. Data
and mobile would pay 16 to 19 extra minutes a build, and the cheapest way out
for them is to find an exception or a workaround, which is how the second
shadow pipeline starts. A path that is better for them needs no enforcement.

### In practice

Treat a team routing around the platform as a bug report. The adoption
metric says *who* left; per-stage timing, broken down by team, says *why*.
Fix the path, then watch the adoption metric move on its own: that is the
validation.

</details>
