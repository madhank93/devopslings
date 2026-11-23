#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A bug is an exception type raised at one place: group the spans' exception
# events by exception.type and the innermost frame of exception.stacktrace,
# count, and rank. The message is useless as a key; it embeds IDs.
set -euo pipefail
python3 - <<'PY'
import collections, json, re, time, urllib.parse, urllib.request
from concurrent.futures import ThreadPoolExecutor

TEMPO = "http://tempo:3200"

def get(path, **params):
    with urllib.request.urlopen(f"{TEMPO}{path}?{urllib.parse.urlencode(params)}", timeout=30) as r:
        return json.load(r)

now = int(time.time())
found = get("/api/search", q='{resource.service.name="checkout" && status=error}',
            start=now - 3600, end=now, limit=100000)["traces"]

def events(tid):
    out = []
    t = get(f"/api/traces/{tid}")
    for b in t.get("batches") or t.get("resourceSpans") or []:
        for ss in b.get("scopeSpans") or []:
            for s in ss.get("spans", []):
                for e in s.get("events", []):
                    a = {x["key"]: x["value"].get("stringValue") for x in e.get("attributes", [])}
                    if e.get("name") == "exception":
                        out.append(a)
    return out

groups = collections.Counter()
with ThreadPoolExecutor(16) as ex:
    for evs in ex.map(events, [t["traceID"] for t in found]):
        for a in evs:
            top = re.findall(r'File "[^"]+", line \d+, in (\S+)', a["exception.stacktrace"])[-1]
            groups[(a["exception.type"], top)] += 1

with open("/obs/answers/issues.txt", "w") as f:
    for (t, fn), n in groups.most_common():
        f.write(f"{t} | {fn} | {n}\n")
print(open("/obs/answers/issues.txt").read())
PY
