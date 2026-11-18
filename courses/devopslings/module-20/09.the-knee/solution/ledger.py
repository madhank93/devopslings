"""Posts one ledger entry: converts it to USD and adds it to the balance."""
from store import fx_rate, ledger_lock, store


def post(entry):
    # The rate lookup does not touch the balance, so it runs outside the lock;
    # only the read-modify-write of the row needs it.
    rate = fx_rate(entry["currency"])
    with ledger_lock:
        balance = store.get()
        store.put(balance + entry["amount"] * rate)
