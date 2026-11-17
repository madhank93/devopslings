# How fast is catalog.price? Prints calls per second.
import time

import catalog

start = time.perf_counter()
for _ in range(200_000):
    catalog.price("SKU-00042")
print(round(200_000 / (time.perf_counter() - start)))
