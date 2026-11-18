"""bench.py QUOTE_PY SECONDS [FOLDED_OUT] — call quote() back to back on the
200 orders in orders.py for SECONDS and print one JSON line: quotes a second.

With FOLDED_OUT, a sampler thread also records the benchmark's stack every
millisecond or so and writes the samples there in folded form, one line per
distinct stack: `frame;frame;frame COUNT`, outermost frame first. That is the
input a flame graph is drawn from.
"""
import collections
import importlib.util
import json
import logging
import os
import sys
import threading
import time

from orders import ORDERS

logging.basicConfig(level=os.environ.get("LOG_LEVEL", "INFO"), stream=sys.stderr,
                    format="%(levelname)s %(name)s %(message)s")

spec = importlib.util.spec_from_file_location("quote", sys.argv[1])
quote = importlib.util.module_from_spec(spec)
spec.loader.exec_module(quote)


def frame_name(f):
    mod = os.path.splitext(os.path.basename(f.f_code.co_filename))[0]
    return f"{mod}.{f.f_code.co_name}"


def sample(target, stop, counts):
    while not stop.is_set():
        f = sys._current_frames().get(target)
        stack = []
        while f is not None:
            stack.append(frame_name(f))
            f = f.f_back
        if stack:
            counts[";".join(reversed(stack))] += 1
        time.sleep(0.001)


def run(seconds):
    n = 0
    end = time.perf_counter() + seconds
    while time.perf_counter() < end:
        for o in ORDERS:
            quote.quote(o)
        n += len(ORDERS)
    return n


seconds = float(sys.argv[2])
folded = sys.argv[3] if len(sys.argv) > 3 else None
counts = collections.Counter()
stop = threading.Event()
if folded:
    threading.Thread(target=sample, args=(threading.get_ident(), stop, counts), daemon=True).start()
start = time.perf_counter()
n = run(seconds)
took = time.perf_counter() - start
stop.set()
if folded:
    with open(folded, "w") as out:
        for stack, c in counts.most_common():
            out.write(f"{stack} {c}\n")
print(json.dumps({"quotes_per_s": int(n / took)}))
