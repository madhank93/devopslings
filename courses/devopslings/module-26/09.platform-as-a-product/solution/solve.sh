#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The largest toil (secret rotation, 21 h/week), the two teams almost off the
# golden path (data 4%, mobile 7%), and the step behind most missed changes
# (runner queue, 3.4%). The three most-voted requests have no data behind them.
set -euo pipefail
mkdir -p /obs/answers
cat > /obs/answers/roadmap.txt <<'TXT'
item: Automate secret rotation | source: toil | metric: platform_toil_hours_weekly{category="secret-rotation"} | target: < 4
item: Golden path fits data and mobile builds | source: adoption | metric: min(platform_golden_path_share{team=~"data|mobile"}) | target: >= 0.6
item: Runner queue stops making changes late | source: slo | metric: platform_journey_bad_ratio{step="queue"} | target: < 0.005
no: Migrate everything to Kubernetes | no adoption, toil or SLO number it would move; the queue and secret rotation are where the time goes
no: Dark mode for the developer portal | popular and cheap to ask for, and it changes none of the numbers the platform is behind on
no: A self-hosted LLM that reviews every pull request | not a platform outcome this quarter; revisit when the journey SLO is met
TXT
