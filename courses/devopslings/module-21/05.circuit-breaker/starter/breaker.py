"""Your circuit breaker. checkout asks it before every call to pricing.

checkout calls these methods under one lock, one caller at a time, so you do
not need your own locking. The pricing call itself runs outside that lock:
while one request is waiting on pricing, others keep calling allow().
"""

import time

# (connect, read) seconds for each call to pricing.
TIMEOUT = (1.0, 2.0)


class Breaker:
    def allow(self):
        """May this request call pricing? False answers it from the fallback price."""
        return True

    def success(self):
        """A call that allow() let through came back with a price."""

    def failure(self):
        """A call that allow() let through failed or timed out."""
