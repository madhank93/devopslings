"""client — charges every order in the batch file, retrying on network errors.

Reads `<order> <customer> <amount>` lines and prints one result per order:

    ok <order> <charge_id>
    FAILED <order> <reason>

The lesson's check reads those lines, so keep the format. It exits non-zero
when any order failed, which is what a customer would see as an error page.
"""

import os
import sys
import time
import uuid

import requests

URL = os.environ.get("PAYMENTS_URL", "http://toxiproxy:21081")
ATTEMPTS = 8


def charge(customer, amount):
    # One key per order, made before the first attempt: every retry of this
    # order carries the same key, which is how the server recognises it.
    key = str(uuid.uuid4())
    last = None
    for _ in range(ATTEMPTS):
        try:
            r = requests.post(
                f"{URL}/charge",
                json={"customer": customer, "amount": amount},
                headers={"Idempotency-Key": key},
                timeout=(1, 3),
            )
            r.raise_for_status()
            return r.json()["charge_id"]
        except requests.RequestException as exc:
            # The request may or may not have reached the server; all the
            # client knows is that no answer came back.
            last = exc
            time.sleep(0.1)
    raise RuntimeError(f"gave up after {ATTEMPTS} attempts: {type(last).__name__}")


def main(path):
    failed = 0
    with open(path) as f:
        for line in f:
            order, customer, amount = line.split()
            try:
                print(f"ok {order} {charge(customer, float(amount))}", flush=True)
            except Exception as exc:
                failed += 1
                print(f"FAILED {order} {exc}", flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "/srv/payments/orders.txt"))
