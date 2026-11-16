"""bench.py NODES SECONDS — run NODES ledger nodes against one balance row and
print {"nodes", "entries_per_s", "lost"} as JSON. Each node fetches an entry
(about 20ms from the queue), then posts it with ledger.post."""
import json
import random
import sys
import threading
import time

import ledger
from store import FX, store

nodes, seconds = int(sys.argv[1]), float(sys.argv[2])
stop = time.monotonic() + seconds
posted, expected = [0] * nodes, [0] * nodes


def node(i):
    rnd = random.Random(i)
    while time.monotonic() < stop:
        time.sleep(0.020)
        entry = {"currency": rnd.choice(list(FX)), "amount": rnd.randint(1, 500)}
        ledger.post(entry)
        posted[i] += 1
        expected[i] += entry["amount"] * FX[entry["currency"]]


threads = [threading.Thread(target=node, args=(i,)) for i in range(nodes)]
start = time.monotonic()
for t in threads:
    t.start()
for t in threads:
    t.join()
took = time.monotonic() - start
lost = sum(expected) - store.get()
print(json.dumps({"nodes": nodes, "entries_per_s": round(sum(posted) / took), "lost": lost}))
