"""bench.py NODES — benchmark the indexer cluster at NODES nodes and print
{"nodes", "per_s"} as JSON.

The cluster is simulated over ten minutes of its own clock, so a run takes
about a second and repeats within a percent or two. Each node loops: build a
batch of documents (about 20ms of its own work), then commit the batch to the
shared index. A commit holds the index's write lock for about 3ms, plus 0.04ms
for every other node, whose cache has to be told the index changed."""
import heapq
import json
import random
import sys

OWN, HELD, PEER, SECONDS = 0.020, 0.003, 0.00004, 600.0

nodes = int(sys.argv[1])
rnd = random.Random()
ready = [(rnd.expovariate(1 / OWN), i) for i in range(nodes)]
heapq.heapify(ready)
unlocked_at, commits = 0.0, 0
while ready:
    t, i = heapq.heappop(ready)
    if t > SECONDS:
        break
    unlocked_at = max(t, unlocked_at) + rnd.expovariate(1 / HELD) + PEER * (nodes - 1)
    if unlocked_at <= SECONDS:
        commits += 1
    heapq.heappush(ready, (unlocked_at + rnd.expovariate(1 / OWN), i))
print(json.dumps({"nodes": nodes, "per_s": round(commits / SECONDS, 1)}))
