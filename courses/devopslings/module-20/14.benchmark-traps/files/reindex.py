"""reindex — the search reindex job that shares the benchmark's core: three
workers that run in bursts together, busy for a moment, idle for a moment,
never on a schedule. Writes its pids to reindex.pid."""
import os
import random
import time

os.sched_setaffinity(0, {1})
seed, start = random.randrange(1 << 30), time.monotonic() + 0.2
for _ in range(2):
    if os.fork() == 0:
        break
else:
    time.sleep(0.1)
with open("reindex.pid", "a") as f:
    f.write(f"{os.getpid()}\n")

# Every worker draws the same schedule, so the bursts land together.
r = random.Random(seed)
t = start
while True:
    t += r.uniform(0.2, 1.2)
    while time.monotonic() < t:
        pass
    t += r.uniform(0.2, 1.2)
    time.sleep(max(0, t - time.monotonic()))
