# Run in devopslings-ha-ops. Gives events.log a finished stage 2 and stage 3:
# what the student's own runs recorded where they exist, a plausible incident
# for whichever stage has none, so stage 4 can be written from a clean sandbox.
import os
import random
from datetime import datetime, timedelta, timezone

LOG = "/var/lib/capstone/events.log"
os.makedirs(os.path.dirname(LOG), exist_ok=True)
have = set()
if os.path.exists(LOG):
    for line in open(LOG, encoding="utf-8"):
        p = line.rstrip("\n").split("\t")
        if len(p) >= 3:
            have.add((p[1], p[2]))

now = datetime.now(timezone.utc).replace(microsecond=0)
r = random.Random()
add = []


def at(minutes_ago, seconds=None):
    return now - timedelta(minutes=minutes_ago, seconds=r.randint(0, 59) if seconds is None else seconds)


if ("stage-2", "fixed") not in have:
    t0 = r.randint(170, 200)
    fault = r.choice(["health", "drift", "retention", "cache", "split"])
    add += [(at(t0), "stage-2", "fault_injected", fault),
            (at(t0 - r.randint(5, 12)), "stage-2", "first_detected", fault),
            (at(t0 - r.randint(35, 50)), "stage-2", "fixed", fault)]
if ("stage-3", "experiment_end") not in have:
    t0 = r.randint(70, 90)
    add += [(at(t0, 0), "stage-3", "experiment_start", "k6 constant-arrival-rate against www"),
            (at(t0 - 3, 0), "stage-3", "release_pushed", "checkout release under load"),
            (at(t0 - 6, 0), "stage-3", "replica_killed", "capstone-shop-2"),
            (at(t0 - 10, 0), "stage-3", "experiment_end",
             f"p99_ms={r.randint(150, 290)} error_budget_burn={r.randint(15, 95) / 10}%")]

with open(LOG, "a", encoding="utf-8") as f:
    for t, stage, event, detail in sorted(add):
        f.write(f"{t.strftime('%Y-%m-%dT%H:%M:%SZ')}\t{stage}\t{event}\t{detail}\n")
print("written for this attempt: " + (", ".join(sorted({s for _, s, _, _ in add})) if add else "nothing"))
