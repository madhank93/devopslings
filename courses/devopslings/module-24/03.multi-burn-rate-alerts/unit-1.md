---
title: "Multi-window burn-rate alerts"
---

## The situation

The shop promises 99.9% of requests succeed over 30 days, so 0.1% may fail:
that is the error budget. Its one availability alert pages whenever more
than 0.1% fail over five minutes. That threshold sounds like the SLO, and it
gets both directions wrong:

- a two-minute spike of errors pages at 3am, though it spent a sliver of
  the month's budget;
- a steady 0.3% leak, which will burn the whole month's budget in ten days,
  pages over and over until people mute it, and nobody files the ticket
  that would get it fixed.

The question an alert should answer is not "are errors above the SLO right
now" but "how fast is the budget going". That is the burn rate: the error
ratio divided by the 0.1% the SLO allows. A burn rate of 1 spends the budget
in exactly 30 days; 14.4 spends 2% of it in an hour.

## Your objectives

Replace the alert in `/obs/prometheus/rules/slo-burn.yml` with burn-rate
alerts, labelled `severity: page` or `severity: ticket`, so that:

1. a fast burn pages within minutes, and stops paging soon after it ends;
2. a slow burn opens a ticket and never pages;
3. a short blip does neither.

## What you're being graded on

The grader replays three histories through your rules with `promtool test
rules`, each after three clean days of traffic at 100 requests a second:

- **fast**: 20% of requests fail for 20 minutes. A page must be firing 10
  minutes in, and not 40 minutes after it ended.
- **slow**: 0.3% fail for 30 hours. No page at any point; a ticket by the
  end.
- **blip**: 10% fail for 2 minutes. Neither a page nor a ticket in the hour
  that follows.

## Try it yourself

Write the error ratio over several windows first (recording rules keep the
alerts readable), then decide which window pairs answer "fast" and which
"slow". `promtool check rules` catches syntax; `obs-reload` loads them.

<details>
<summary>Hint 1 — the threshold</summary>

A burn rate is compared against the error ratio as `ratio > rate x 0.001`.
Writing `ratio > 14.4` compares a fraction to fourteen, and never fires.
For a page, the Google SRE Workbook uses 14.4 (2% of a 30-day budget in an
hour) and 6 (5% in six hours); for a ticket, 1 (10% in three days).

</details>

<details>
<summary>Hint 2 — two windows each</summary>

A long window alone is slow to start and slow to stop: after the burn ends,
it keeps firing until the bad minutes slide out of it. A short window alone
is a spike detector. Require both: the long one says the burn is
significant, the short one says it is still happening. A short window of
about a twelfth of the long one is the usual choice.

</details>

<details>
<summary>Solution</summary>

```yaml
groups:
  - name: shop-slo
    rules:
      - record: shop:error_ratio:rate5m
        expr: sum(rate(shop_http_requests_total{job="shop",code=~"5.."}[5m])) / sum(rate(shop_http_requests_total{job="shop"}[5m]))
      - record: shop:error_ratio:rate30m
        expr: sum(rate(shop_http_requests_total{job="shop",code=~"5.."}[30m])) / sum(rate(shop_http_requests_total{job="shop"}[30m]))
      - record: shop:error_ratio:rate1h
        expr: sum(rate(shop_http_requests_total{job="shop",code=~"5.."}[1h])) / sum(rate(shop_http_requests_total{job="shop"}[1h]))
      - record: shop:error_ratio:rate6h
        expr: sum(rate(shop_http_requests_total{job="shop",code=~"5.."}[6h])) / sum(rate(shop_http_requests_total{job="shop"}[6h]))
      - record: shop:error_ratio:rate3d
        expr: sum(rate(shop_http_requests_total{job="shop",code=~"5.."}[3d])) / sum(rate(shop_http_requests_total{job="shop"}[3d]))
      - alert: ShopBudgetFastBurn
        expr: |
          (shop:error_ratio:rate1h > 14.4 * 0.001 and shop:error_ratio:rate5m > 14.4 * 0.001)
          or
          (shop:error_ratio:rate6h > 6 * 0.001 and shop:error_ratio:rate30m > 6 * 0.001)
        for: 2m
        labels: {severity: page}
      - alert: ShopBudgetSlowBurn
        expr: shop:error_ratio:rate3d > 1 * 0.001 and shop:error_ratio:rate6h > 1 * 0.001
        for: 1h
        labels: {severity: ticket}
```

### Why each history comes out as it does

The fast burn (200x) pushes the 1h ratio over 1.44% about five minutes in,
and the 5m ratio is already there: page. When it stops, the 5m ratio drops
within five minutes and the 6h/30m pair within half an hour, so the page
resolves; a 1h-only rule would page for an hour after the fix.

The slow burn (3x) never gets near 6x or 14.4x, so it never pages. About
21 hours in, the 3-day ratio crosses 0.1% while the 6h one confirms it is
still going: ticket, an hour later (its `for:`).

The blip spends under half a percent of the month's budget. The 5m ratio jumps to
4%, which is why a 5m-only alert pages on it, but the 1h ratio only reaches
0.3%, under 1.44%, so the pair stays quiet.

</details>
