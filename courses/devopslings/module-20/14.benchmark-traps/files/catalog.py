"""catalog — list prices for the storefront. price(sku) is what every product
page calls.

The rate table is built on first use, which takes a moment, and the last 2,048
prices asked for are cached.
"""
import functools
import os

_table = None
# The check doubles the cost of a price to see whether a benchmark notices.
WORK = 2 if os.environ.get("CATALOG_SLOW") else 1


def _load():
    global _table
    _table = [((i * 2654435761) % 1000003) / 1000.0 for i in range(1_500_000)]


@functools.lru_cache(maxsize=2048)
def price(sku):
    if _table is None:
        _load()
    n = int(sku[4:])
    total = 0.0
    for k in range(40 * WORK):
        total += _table[(n * 31 + k * 7919) % len(_table)]
    return round(total / (40 * WORK), 2)
