#!/usr/bin/env bash
# The reference write-up: the postmortem from events.log, and a runbook whose
# commands all work against ha-stack.
set -euo pipefail
S="$DEVOPSLINGS_ROOT/scratch/stage-4-write-it-up"
mkdir -p "$S"

docker exec -i devopslings-ha-ops python3 - > "$S/postmortem.md" <<'PY'
import re
from datetime import datetime, timedelta

ev = sorted(l.rstrip("\n").split("\t") for l in open("/var/lib/capstone/events.log") if l.count("\t") >= 2)
last = {}
for t, stage, name, *d in ev:
    last[name] = (datetime.strptime(t, "%Y-%m-%dT%H:%M:%SZ"), d[0] if d else "")
at = lambda n: last[n][0].strftime("%Y-%m-%d %H:%M UTC")
fault = last["fault_injected"][1]
kv = dict(re.findall(r"(\w+)=([-\d.]+%?)", last["experiment_end"][1]))
mins = round((last["fixed"][0] - last["fault_injected"][0]).total_seconds() / 60)
due = lambda days: (last["experiment_end"][0] + timedelta(days=days)).strftime("%Y-%m-%d")

cause = {
    "health": "/health answered ok without asking pricing, so the load balancers kept a replica that could not take orders in rotation",
    "drift": "a replica removed outside the pipeline left production smaller than its code, and nothing compared the two",
    "retention": "the retention job kept one release, so the image a rollback needed had already been deleted",
    "cache": "the build cache returned the first build's bundle for every later build, so green pipelines shipped old code",
    "split": "a second workspace owned the replicas, so the pipeline's state no longer described production",
}.get(fault, f"the {fault} fault went in on a path no check covered")

tl = [("fault_injected", f"the {fault} fault goes into the commit-to-www path")]
if "first_detected" in last and last["fault_injected"][0] <= last["first_detected"][0] <= last["fixed"][0]:
    tl.append(("first_detected", "the symptom is first noticed"))
tl += [("fixed", "the fix ships through the pipeline and the fault's own check passes"),
       ("experiment_start", "stage 3's chaos experiment starts: constant-rate load against www"),
       ("release_pushed", "a release is pushed through the pipeline under load"),
       ("replica_killed", "a replica is killed under load"),
       ("experiment_end", f"the experiment ends: p99 {kv.get('p99_ms')} ms, error budget burn {kv.get('error_budget_burn')}")]

print(f"""# Postmortem: checkout, {last['fault_injected'][0]:%Y-%m-%d}

## Summary

The {fault} fault was live in checkout's path for about {mins} minutes before a
fix shipped through the pipeline. The chaos experiment that followed, a release
and a killed replica under load, held the SLO.

## Impact

During the experiment checkout's p99 latency was {kv.get('p99_ms')} ms, and it burned
{kv.get('error_budget_burn')} of the 30-day error budget against the 99.9% availability SLO.
The fault itself was live for {mins} minutes, from {at('fault_injected')} to {at('fixed')}.

## Timeline
""")
for n, what in tl:
    if n in last:
        print(f"- {at(n)}  {what}")
print(f"""
## Contributing factors

- {cause[0].upper()}{cause[1:]}.
- No alert watched the symptom: the fault was found by a person looking, not by a page.
- The fix could only reach production through a full pipeline run, so time to repair was bounded by build and deploy time.

## Action items

- marco | page on the checkout error rate and p99 burn rate against the SLO | {due(7)}
- priya | add the fault's own check to the pipeline, so the release is refused while it fails | {due(14)}
- sam | add a health check that exercises what an order needs, and a test for it | {due(14)}
- priya | keep a rollback image and a one-command redeploy of the previous digest | {due(30)}""")
PY

cat > "$S/runbook.md" <<'MD'
# Runbook: checkout

## Roles

One person each, named when the incident is declared:

- incident commander: decides and coordinates; does not debug or change systems.
- operations lead: investigates and changes the system.
- communications lead: writes every status update.

## Severity

- SEV1: more than 25% of requests to www failing, or more than 10% of the 30-day error budget burned in an hour.
- SEV2: 1-25% of requests failing, or p99 over 500 ms for 5 minutes.
- SEV3: under 1% failing and p99 within the SLO; internal only.

## Is www serving?

```sh
docker exec devopslings-ha-ops curl -s -o /dev/null -w 'www %{http_code}\n' --max-time 3 http://www/
```

## Which replicas are in rotation?

```sh
for lb in lb1 lb2; do
  docker exec devopslings-ha-ops curl -fsS --max-time 2 "http://$lb:8404/stats;csv" \
    | awk -F, -v lb="$lb" '$1 == "app" && $2 ~ /^shop/ { print lb, $2, $18 }'
done
```

## What is each replica running?

```sh
docker ps --filter name=capstone-shop --format '{{.Names}} {{.Status}} {{.Image}}'
docker exec devopslings-ha-ops curl -fsS --max-time 3 http://172.29.22.31:8080/health
docker exec devopslings-ha-ops curl -fsS --max-time 3 http://172.29.22.32:8080/health
docker logs --tail 20 capstone-shop-1
```

## Restart one replica, and wait until it is back in rotation

Never both at once: the other one carries the traffic.

```sh
docker restart capstone-shop-1
for i in $(seq 30); do
  st=$(docker exec devopslings-ha-ops curl -fsS --max-time 2 'http://lb1:8404/stats;csv' \
         | awk -F, '$1 == "app" && $2 == "shop1" { print $18 }')
  [ "$st" = UP ] && break
  sleep 1
done
[ "$st" = UP ]
```

## Roll back

Through the pipeline only, never by hand: revert the bad commit on main and
push. The deploy job applies the previous digest from shared state.

```text
git revert --no-edit <bad commit> && git push origin main
```
MD
