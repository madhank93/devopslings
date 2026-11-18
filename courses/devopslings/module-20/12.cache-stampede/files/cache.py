"""The catalog API's cache. get() is called for every request, from many
threads at once; load(key) queries catalog-db (about 150ms)."""
import time

TTL = 15.0  # seconds; prices may be at most 15 seconds stale
_store = {}  # key -> (value, expires_at)


def get(key, load):
    hit = _store.get(key)
    if hit and hit[1] > time.monotonic():
        return hit[0]
    value = load(key)
    _store[key] = (value, time.monotonic() + TTL)
    return value
