"""Posts one ledger entry: converts it to USD and adds it to the balance."""
from store import fx_rate, ledger_lock, store


def post(entry):
    with ledger_lock:
        rate = fx_rate(entry["currency"])
        balance = store.get()
        store.put(balance + entry["amount"] * rate)
