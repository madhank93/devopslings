# The reference measurement the check holds a benchmark to: calls a second of
# catalog.price on the production key sample, in a warm process.
import time

import catalog
from workload import KEYS

# Warm-up: the first pass pays for loading the rate table and fills the cache
# the way production traffic would. Neither happens again in a running server.
for k in KEYS:
    catalog.price(k)

# Something else can share the core, and interference only ever adds time:
# the fastest of several full passes is the code's own speed.
best = float("inf")
for _ in range(15):
    start = time.perf_counter()
    for k in KEYS:
        catalog.price(k)
    best = min(best, time.perf_counter() - start)
print(round(len(KEYS) / best))
