"""quote — prices a freight order: base rate by weight band, surcharges,
promotions, then rounding to the cent. One call to quote() per request.
"""
import json
import logging
from decimal import ROUND_HALF_EVEN, Decimal

log = logging.getLogger("quote")

BANDS = [(1, 4.10), (5, 3.65), (20, 3.05), (100, 2.40), (500, 1.95), (10**9, 1.60)]
SURCHARGES = {"hazmat": 0.18, "fragile": 0.07, "remote": 0.11, "weekend": 0.05}
PROMOTIONS = [
    {"code": f"P{n:03d}", "min_kg": n % 40, "lanes": {f"L{(n * 7) % 90}", f"L{(n * 11) % 90}"},
     "off": 0.01 + (n % 9) / 100}
    for n in range(160)
]


def base_rate(kg):
    for limit, per_kg in BANDS:
        if kg <= limit:
            return kg * per_kg
    raise ValueError(kg)


def surcharges(order, amount):
    return sum(amount * SURCHARGES[f] for f in order["flags"] if f in SURCHARGES)


def apply_promotions(order, amount):
    """The best promotion the order qualifies for. Every promotion is checked
    against every line, so this is the step everyone assumes is slow."""
    best = 0.0
    for promo in PROMOTIONS:
        for line in order["lines"]:
            if line["lane"] in promo["lanes"] and line["kg"] >= promo["min_kg"]:
                best = max(best, promo["off"])
    return amount * (1 - best)


def to_cents(amount):
    return int(Decimal(str(amount)).quantize(Decimal("0.01"), ROUND_HALF_EVEN) * 100)


def quote(order):
    log.debug(f"quoting order {json.dumps(order, indent=2, sort_keys=True)}")
    kg = sum(line["kg"] for line in order["lines"])
    amount = base_rate(kg)
    amount += surcharges(order, amount)
    amount = apply_promotions(order, amount)
    return to_cents(amount)
