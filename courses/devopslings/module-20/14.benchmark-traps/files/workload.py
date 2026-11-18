"""KEYS — a sample of the SKUs product pages asked for, in the order they asked:
20,000 lookups over 50,000 products. About a third are for the 500 bestsellers,
the rest are spread over everything else."""
import random

_r = random.Random(1409)
KEYS = [f"SKU-{_r.randrange(500) if _r.random() < 0.3 else _r.randrange(50_000):05d}"
        for _ in range(20_000)]
