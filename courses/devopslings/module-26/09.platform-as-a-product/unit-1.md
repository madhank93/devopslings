---
title: "A roadmap from the data, not from the loudest request"
---

## The situation

Planning is next week. The request board, `/obs/platform/requests.md`, has
three clear winners: migrate everything to Kubernetes (41 votes), dark mode
for the developer portal (33), and an LLM that reviews every pull request
(29). Votes are cheap, and they measure what people noticed, not what costs
them time.

The platform also has a quarter of data that nobody has put side by side:

- **adoption** — each team's share of builds on the golden path
- **toil** — platform engineer hours a week on manual work, by category
- **the platform SLO** — the share of changes that reached production within
  30 minutes, and which step made the rest miss it

## Your objectives

Write `/obs/answers/roadmap.txt` in the format of
`/obs/platform/ROADMAP-FORMAT.md`:

1. At least three items, at least one each from adoption, toil and SLO data.
   Each item names the query that measures it and a target that today's
   number does not already meet.
2. Each item goes after the biggest gap in its data, not a convenient one.
3. At least one `no:` line that turns down a request from the board, with a
   reason.

## Getting started

You work in the `box` container. The data comes from a simulator,
`/obs/apps/gateway_exporter.py`, that serves the quarter's numbers. It is a
model, and the check refuses to run if it was edited.

```
curl -s gateway-exporter:9101/metrics | grep '^platform_'
promq 'sort_desc(platform_toil_hours_weekly)'
```

## What you're being graded on

For every `item:` line:

- it is not one of the board's unsupported requests;
- `source:` is `adoption`, `toil` or `slo`;
- `metric:` is a query Prometheus runs and that returns a number today;
- `target:` is a comparison and a number, and today's number does not meet it;
- the metric is the largest gap in that source: the biggest toil category,
  a team almost entirely off the golden path, the step that makes the most
  changes late (or the overall SLI).

And at least one `no:` line turns down a board request with a reason of at
least six words.

<details>
<summary>Hint 1 — reading each source</summary>

Sort each metric. Toil has one category bigger than the next three together.
Adoption has two teams under 10%. The bad-ratio metric breaks the late
changes down by the step that made them late, and one step dominates.

</details>

<details>
<summary>Hint 2 — a target that measures something</summary>

The target is where the number has to be at the end of the quarter for the
item to count as done. If today's value already meets it, the item is done
before it starts. Pick a direction (`<` for hours and bad ratios, `>=` for
shares) and a number that would be a real change.

</details>

<details>
<summary>Solution</summary>

```
item: Automate secret rotation | source: toil | metric: platform_toil_hours_weekly{category="secret-rotation"} | target: < 4
item: Golden path fits data and mobile builds | source: adoption | metric: min(platform_golden_path_share{team=~"data|mobile"}) | target: >= 0.6
item: Runner queue stops making changes late | source: slo | metric: platform_journey_bad_ratio{step="queue"} | target: < 0.005
no: Migrate everything to Kubernetes | no adoption, toil or SLO number it would move; the queue and secret rotation are where the time goes
no: Dark mode for the developer portal | popular and cheap to ask for, and it changes none of the numbers the platform is behind on
no: A self-hosted LLM that reviews every pull request | not a platform outcome this quarter; revisit when the journey SLO is met
```

### Why votes are the wrong input

A vote is free and measures visibility. Kubernetes is what people read
about; dark mode is what they look at every day. Neither shows up in the
numbers that say where developers lose time or where the platform team's
week goes. The board is still useful: one of its low-voted entries, "stop
rotating secrets by hand", is the largest toil there is.

### Why the "no" list is part of the plan

A roadmap that only lists what it will do invites everything else back in,
one meeting at a time. Saying no, with the reason in the data, is what makes
the plan survive contact with the 41 people who voted for something else.

### In practice

Platform-as-a-product means the platform has users, and the roadmap is
judged by what changes for them. Each item carries its own success
criterion, a query and a target, so the end-of-quarter review is a query
rather than an opinion.

</details>
