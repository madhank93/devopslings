"""The shared pieces every ledger node talks to. Not yours to change: the
check runs your ledger.py against this copy."""
import threading
import time

FX = {"EUR": 108, "GBP": 127, "USD": 100}  # cents of USD per unit


def fx_rate(currency):
    """A round trip to the rates service: about 5ms."""
    time.sleep(0.005)
    return FX[currency]


class _Store:
    """The balance row. get and put are each a short round trip, so a
    read-modify-write that is not under a lock loses updates."""

    def __init__(self):
        self._v = 0

    def get(self):
        time.sleep(0)
        return self._v

    def put(self, v):
        time.sleep(0)
        self._v = v


class _LedgerLock:
    """The lock on the balance row. Handing it on costs more the more nodes
    are queued for it: each waiter is another node polling the same row."""

    def __init__(self):
        self._lock = threading.Lock()
        self._waiting = 0
        self._count = threading.Lock()

    def __enter__(self):
        if not self._lock.acquire(blocking=False):
            with self._count:
                self._waiting += 1
            self._lock.acquire()
            with self._count:
                self._waiting -= 1
                waiting = self._waiting
            time.sleep(0.0015 * waiting)
        return self

    def __exit__(self, *a):
        self._lock.release()


store = _Store()
ledger_lock = _LedgerLock()
