"""The 200 freight orders the benchmark and the check price. Fixed seed, so
every run prices the same orders."""
import random

rnd = random.Random(2071)
FLAGS = ["hazmat", "fragile", "remote", "weekend", "liftgate", "signature"]


def order(n):
    return {
        "id": f"FR-{40000 + n}",
        "customer": {"account": f"AC{rnd.randint(1000, 9999)}", "name": f"Customer {n}",
                     "address": {"street": f"{rnd.randint(1, 900)} Dock Road", "city": "Port Kessel",
                                 "postcode": f"PK{rnd.randint(10, 99)} {rnd.randint(1, 9)}QX"}},
        "flags": rnd.sample(FLAGS, rnd.randint(0, 3)),
        "lines": [{"sku": f"SKU-{rnd.randint(1, 50000)}", "lane": f"L{rnd.randint(0, 89)}",
                   "kg": round(rnd.uniform(0.2, 60), 2), "pallets": rnd.randint(0, 4),
                   "notes": rnd.choice(["", "stack max 2", "keep dry", "tail lift needed"])}
                  for _ in range(rnd.randint(8, 16))],
    }


ORDERS = [order(n) for n in range(200)]
