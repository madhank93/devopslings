# Stage 4's rubric: 24/13's postmortem checks and 24/09's roles and severity,
# against the times stages 2 and 3 recorded.
# Usage: grade.py postmortem.md runbook.md events.log team.txt
import re
import sys
from datetime import datetime, timezone

PM, RB, LOG, TEAM = sys.argv[1:5]
TOLERANCE = 120  # seconds a timeline entry may be off the logged event


def fail(*lines):
    print("not yet: " + lines[0])
    for l in lines[1:]:
        print("         " + l)
    sys.exit(1)


def stamp(t):
    return t.strftime("%Y-%m-%d %H:%M UTC")


def read(path, name):
    try:
        return open(path, encoding="utf-8").read()
    except OSError:
        fail(f"scratch/stage-4-write-it-up/{name} is missing.")


# ---- what stages 2 and 3 recorded -------------------------------------------
events = []
for line in open(LOG, encoding="utf-8"):
    p = line.rstrip("\n").split("\t")
    if len(p) < 3:
        continue
    try:
        t = datetime.strptime(p[0], "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)
    except ValueError:
        continue
    events.append((t, p[1], p[2], p[3] if len(p) > 3 else ""))
events.sort(key=lambda e: e[0])


def last(stage, name, after=None, before=None):
    hits = [e for e in events if e[1] == stage and e[2] == name
            and (after is None or e[0] >= after[0]) and (before is None or e[0] <= before[0])]
    return hits[-1] if hits else None


fixed = last("stage-2", "fixed")
end3 = last("stage-3", "experiment_end")
if not fixed or not end3:
    fail("events.log has no finished stage 2 or stage 3 in it. Start the lesson again; its",
         "init writes the events when the earlier stages have not.")
start2 = last("stage-2", "fault_injected", before=fixed)
start3 = last("stage-3", "experiment_start", before=end3)
LABEL = {
    "fault_injected": "stage 2's fault going in",
    "first_detected": "stage 2's fault first being detected",
    "fixed": "stage 2's fix passing its check",
    "experiment_start": "stage 3's experiment starting",
    "release_pushed": "stage 3's release being pushed",
    "replica_killed": "stage 3's replica being killed",
    "experiment_end": "stage 3's experiment ending",
}
need = [start2, last("stage-2", "first_detected", start2, fixed), fixed,
        start3, last("stage-3", "release_pushed", start3, end3),
        last("stage-3", "replica_killed", start3, end3), end3]
need = sorted((e for e in need if e), key=lambda e: e[0])

kv = dict(re.findall(r"(\w+)=([-\d.]+)", end3[3]))
P99 = float(kv["p99_ms"]) if "p99_ms" in kv else None
BURN = float(kv["error_budget_burn"]) if "error_budget_burn" in kv else None

team = {l.split()[0].lower() for l in open(TEAM, encoding="utf-8") if l.strip() and not l.startswith("#")}

# ---- the postmortem's sections ----------------------------------------------
text = read(PM, "postmortem.md")
lines, fenced = [], False
for l in text.splitlines():
    if l.lstrip().startswith("```"):
        fenced = not fenced
    elif not fenced:
        lines.append(l)

sections, cur = {}, None
for l in lines:
    h = re.match(r"#{1,4}\s+(.*)", l)
    if h:
        cur = h.group(1).strip().lower()
        sections[cur] = []
    elif cur is not None:
        sections[cur].append(l)


def section(word, title):
    for k, v in sections.items():
        if word in k:
            return v
    fail(f"postmortem.md has no '## {title}' section.")


def items(body):
    out = []
    for l in body:
        m = re.match(r"\s*(?:[-*+]|\d+[.)])\s+(.*\S)", l)
        if m:
            out.append(m.group(1))
    return out


timeline = items(section("timeline", "Timeline"))
impact = " ".join(section("impact", "Impact"))
factors = items(section("contributing", "Contributing factors"))
actions = items(section("action", "Action items"))

# ---- blame, anywhere ----------------------------------------------------------
names = "|".join(sorted(team))
WHO = rf"(?:{names}|he|she|someone|somebody|the (?:engineer|reviewer|developer|author|on-?call|operator))"
BLAME = re.compile(rf"\b(?:blame\w*|careless\w*|negligen\w*|sloppy|incompeten\w*|human error|operator error|"
                   rf"{WHO}\s+(?:should(?:n't| not)? have|failed to|forgot|neglected|ignored|didn't bother|messed up|broke)|"
                   rf"{WHO}'s\s+(?:\w+\s+)?(?:mistake|error|fault|blunder))\b", re.I)
for l in lines:
    m = BLAME.search(l)
    if m:
        fail(f"postmortem.md says '{m.group(0)}': \"{l.strip()[:90]}\"",
             "That is a judgement of a person, and a postmortem that judges people gets less",
             "honest every time. Say what happened, and what in the system allowed it.")

# ---- the timeline, against the log ------------------------------------------
TS = re.compile(r"[`*_]*(\d{4}-\d\d-\d\d)[T ](\d\d:\d\d)(?::\d\d)?\s*(?:Z|UTC)?[`*_]*\s*(.*)", re.I)
when = []
for t in timeline:
    m = TS.match(t)
    if not m:
        fail(f"the timeline entry '{t[:70]}' has no time in front of it.",
             "Write each entry as '- YYYY-MM-DD HH:MM UTC  what happened', the way events.log does.")
    if not m.group(3).strip(" -—:|"):
        fail(f"the timeline entry '{t}' says when, but not what happened.")
    when.append(datetime.strptime(f"{m.group(1)} {m.group(2)}", "%Y-%m-%d %H:%M").replace(tzinfo=timezone.utc))
for a, b in zip(when, when[1:]):
    if b < a:
        fail(f"the timeline is out of order: {stamp(b)} comes after {stamp(a)}.",
             "A timeline is read top to bottom as what happened next.")

# Each event takes the first unused entry within the tolerance, in order.
i = 0
for e in need:
    j = next((k for k in range(i, len(when)) if abs((when[k] - e[0]).total_seconds()) <= TOLERANCE), None)
    if j is not None:
        i = j + 1
        continue
    what = f"{LABEL[e[2]]}, at {stamp(e[0])}"
    # An entry that belongs to another event is not a near miss for this one.
    spare = [w for w in when if all(abs((w - o[0]).total_seconds()) > TOLERANCE for o in need)]
    near = min(spare, key=lambda w: abs((w - e[0]).total_seconds()), default=None)
    if near is not None:
        d = (near - e[0]).total_seconds()
        h = round(d / 3600)
        if h and abs(d - h * 3600) <= TOLERANCE:
            fail(f"the timeline has nothing within two minutes of {what}.",
                 f"Its {stamp(near)} entry is exactly {abs(h)} hour(s) off: events.log is in UTC, and",
                 "a timeline in local time cannot be lined up with anything else.")
        if abs(d) <= 15 * 60:
            fail(f"the timeline has nothing within two minutes of {what}.",
                 f"The nearest entry is {stamp(near)}, {abs(d) / 60:.0f} minutes off. Take the times from",
                 "events.log, not from memory.")
    fail(f"the timeline has nothing within two minutes of {what} (events.log).",
         "A postmortem timeline runs from the fault going in, through detection, to the fix,",
         "and through each step of the experiment.")

# ---- impact, in SLO terms -----------------------------------------------------
if not impact.strip():
    fail("the Impact section is empty.")
nums = [n for n in re.findall(r"\d+(?:\.\d+)?", impact)]


def quoted(v):
    for n in nums:
        d = len(n.split(".")[1]) if "." in n else 0
        for c in (v, v * 100, v / 100):
            if round(c, d) == float(n) and abs(float(n) - c) <= 0.05 * abs(c):
                return True
    return False


if not re.search(r"\bSLO\b|error budget|\bp99\b", impact, re.I):
    fail("the impact says what people saw, but not in SLO terms.",
         "Impact is measured against the objective: the p99 latency and the share of the error",
         "budget the experiment burned, from stage 3's experiment_end line in events.log.")
if P99 is not None and not (re.search(r"\bp99\b", impact, re.I) and quoted(P99)):
    fail(f"the impact does not quote the p99 stage 3 measured: experiment_end logged p99_ms={kv['p99_ms']}.",
         "Latency is part of the SLO; say what it was, from the measurement.")
if BURN is not None and not (re.search(r"budget", impact, re.I) and quoted(BURN)):
    fail(f"the impact does not quote the error budget burned: experiment_end logged",
         f"error_budget_burn={kv['error_budget_burn']}. How much of the budget an incident spent is what",
         "decides whether the next release waits.")

# ---- contributing factors -----------------------------------------------------
if len(factors) < 3:
    fail(f"there {'is' if len(factors) == 1 else 'are'} {len(factors)} contributing factor(s). One fault started it;",
         "what let it in, kept it unnoticed, and kept it live until the fix?")
for t in factors:
    who = [p for p in team if re.search(rf"\b{p}\b", t, re.I)]
    if who:
        fail(f"the factor '{t[:70]}' names {who[0]}.",
             "Contributing factors are conditions in the system: the check that passed it, the alert",
             "that did not fire. A person is never the condition; the place they stood is.")
if not re.search(r"alert|monitor|detect|page|paging|dashboard|metric|test|canary|probe|health", " ".join(factors), re.I):
    fail("no factor is about why it was not caught sooner: what watched for it, and why did that",
         "not fire?")

# ---- action items ---------------------------------------------------------------
TRY_HARDER = re.compile(r"\b(be (more )?careful|carefully|remember to|pay (more )?attention|double[- ]check|"
                        r"retrain\w*|training|remind\w*|try harder)\b", re.I)
if len(actions) < 3:
    fail(f"there {'is' if len(actions) == 1 else 'are'} {len(actions)} action item(s); each contributing factor needs at least one.")
after = need[-1][0].date()
for t in actions:
    p = [x.strip(" `*") for x in t.split("|")]
    if len(p) != 3:
        fail(f"the action '{t[:70]}' should read '- owner | what | YYYY-MM-DD'.")
    owner, what, due = p[0].lower(), p[1], p[2]
    if owner not in team:
        fail(f"an action is owned by '{p[0]}': {what}",
             "An action owned by a team, 'TBD' or everyone is owned by nobody, and it is still open at",
             "the next incident. One person from team.txt, who will see it through.")
    try:
        d = datetime.strptime(due, "%Y-%m-%d").date()
    except ValueError:
        d = None
    if d is None or d <= after:
        fail(f"an action is due '{due}': {what}", f"Give it a date after the incident ({after}), as YYYY-MM-DD.")
    m = TRY_HARDER.search(what)
    if m:
        fail(f"the action '{what}' asks for '{m.group(0)}'.",
             "Asking people to try harder is blame written as an action; it fails the next tired",
             "person the same way. Change what they work with: a check, an alert, a faster path.")

# ---- the runbook: who does what, and when it is an incident ----------------------
rb = read(RB, "runbook.md")
for role, rx in (("incident commander", r"commander"), ("operations lead", r"operations lead|ops lead"),
                 ("communications lead", r"communications lead|comms lead")):
    if not re.search(rx, rb, re.I):
        fail(f"runbook.md does not say who is the {role}.",
             "An incident needs three roles, one person each: the commander decides, operations",
             "changes the system, communications writes the updates. Name them before they are needed.")
sev = {}
for l in rb.splitlines():
    m = re.search(r"\bSEV ?([1-4])\b", l, re.I)
    if m and m.group(1) not in sev:
        sev[m.group(1)] = l
if len(sev) < 2:
    fail("runbook.md does not define severities. Give at least two levels, SEV1 and SEV2, each",
         "with the line that makes an incident that severe.")
for n, l in sorted(sev.items()):
    if not re.search(r"\bSLO\b|budget|\bp99\b|\d+ ?(%|ms)", l, re.I):
        fail(f"SEV{n} is defined as '{l.strip()[:70]}'.",
             "Severity is decided by the numbers the SLO is written in, an error rate, a p99 or a",
             "budget burn, so that two people looking at the same graph make the same call.")

print(f"timeline: {len(need)} logged events matched within two minutes, in order")
print(f"impact quotes p99 {kv.get('p99_ms', '?')} ms and an error budget burn of {kv.get('error_budget_burn', '?')}")
print(f"{len(factors)} contributing factors, none a person; {len(actions)} actions, each owned and dated")
print(f"runbook names the three roles and {len(sev)} severities in SLO terms")
