"""Grades one batch run: client.py's output on stdin, the ledger on disk.

Runs inside the payments container after run.sh, so the probes reach
payments.py directly and bypass the fault on the proxy.
"""

import collections
import sqlite3
import sys
import uuid

import requests

ORDERS = 30
# Mirrors the batch run.sh generates.
CUSTOMERS = ["alice", "bob", "carol", "dan", "erin"]
AMOUNTS = [9.99, 12.50, 20.00]
expected = collections.Counter(
    (CUSTOMERS[i % 5], AMOUNTS[i % 3]) for i in range(1, ORDERS + 1)
)

ok, failed = {}, []
for line in sys.stdin.read().splitlines():
    parts = line.split()
    if len(parts) >= 3 and parts[0] == "ok":
        ok[parts[1]] = parts[2]
    elif parts and parts[0] == "FAILED":
        failed.append(line)

try:
    rows = (
        sqlite3.connect("/srv/payments/ledger.db")
        .execute("SELECT id, customer, amount FROM charges")
        .fetchall()
    )
except sqlite3.Error as exc:
    print(f"not yet: could not read the ledger ({exc}). The check counts rows in the")
    print("charges table, so keep it, with its id, customer and amount columns.")
    sys.exit(1)
got = collections.Counter((c, round(float(a), 2)) for _, c, a in rows)
n = len(rows)


def post(key):
    try:
        r = requests.post(
            "http://localhost:8081/charge",
            json={"customer": "probe", "amount": 1.00},
            headers={"Idempotency-Key": key},
            timeout=5,
        )
    except requests.RequestException as exc:
        return (type(exc).__name__, None)
    try:
        cid = r.json().get("charge_id") if r.ok else None
    except ValueError:
        cid = None
    return (r.status_code, cid)


key = str(uuid.uuid4())
first, replay, other = post(key), post(key), post(str(uuid.uuid4()))
replay_ok = isinstance(replay[0], int) and 200 <= replay[0] < 300
key_honoured = first[1] is not None and replay_ok and replay[1] == first[1]
keys_distinct = other[1] is not None and other[1] != first[1]


def pairs(counter):
    return ", ".join(f"{c} {a:.2f} x{k}" for (c, a), k in sorted(counter.items()))


print(f"batch: {len(ok)} of {ORDERS} orders answered ok, {len(failed)} FAILED; ledger: {n} charges")
print()

if n > ORDERS:
    print(f"not yet: {ORDERS} orders, {n} charges — {n - ORDERS} payments were charged twice.")
    print(f"  extra charges: {pairs(got - expected)}")
    print("A response was lost after the charge was recorded, the client retried, and")
    print("the retry was charged as a new payment.")
    if not key_honoured:
        print(f"Probe: two POSTs with the same Idempotency-Key got {first} then {replay}")
        print("(status, charge_id). payments.py has to remember a key it has charged and")
        print("answer a repeat of it with that same charge.")
    else:
        print(f"Probe: payments.py does return the original charge for a repeated key")
        print(f"(charge {first[1]} both times), so the retries in the batch did not reach it")
        print("with the key of their first attempt. Look at when client.py makes the key,")
        print("and whether every attempt sends it.")
    sys.exit(1)

if failed:
    print(f"not yet: {len(failed)} of {ORDERS} orders were reported FAILED to the customer:")
    for line in failed[:3]:
        print(f"  {line}")
    if not replay_ok:
        print(f"Probe: replaying an Idempotency-Key got {replay[0]}. A retry whose first")
        print("attempt was charged needs that charge back, not an error, or the client")
        print("can never tell the customer it worked.")
    elif n == ORDERS:
        print(f"Yet the ledger has all {ORDERS} charges: those customers paid and were told")
        print("they had not. A lost response is not a failed payment, so the client has")
        print("to retry — and the retry has to be safe to repeat.")
    else:
        print(f"The ledger has {n} charges for {ORDERS} orders.")
    sys.exit(1)

if n < ORDERS or got != expected:
    print(f"not yet: {ORDERS} orders, {n} charges. Orders that were never charged:")
    print(f"  {pairs(expected - got)}  (customer, amount, how many)")
    print("Every customer and amount in the batch is ordered twice, and those are two")
    print("purchases. A retry is recognised by its key, not by looking like an")
    print("earlier request.")
    if not keys_distinct:
        print(f"Probe: two POSTs with different keys and the same body got {first} and")
        print(f"{other} — the second purchase was not charged.")
    sys.exit(1)

if set(ok.values()) != {str(r[0]) for r in rows}:
    print("not yet: the ledger is right, but the charge ids the client reported do not")
    print("match it — a retry has to be answered with the charge its first attempt made.")
    sys.exit(1)

if not key_honoured or not keys_distinct:
    print("not yet: the batch came out right, but the probe that replays a request")
    print(f"directly did not: same key got {first} then {replay}, a new key got {other}")
    print("(status, charge_id). The batch's fault is random; this probe is not.")
    print("The server must answer a repeated Idempotency-Key with the original charge,")
    print("and charge a new key as a new payment.")
    sys.exit(1)

print(f"PASS — {ORDERS} orders, {ORDERS} charges, every customer told the truth,")
print("while one response in four was lost on the way back.")
