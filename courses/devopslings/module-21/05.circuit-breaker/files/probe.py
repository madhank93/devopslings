"""Client for the circuit-breaker harness, run inside the checkout container.

  probe.py restart          (re)start the harness with a fresh Breaker
  probe.py seq N [GAP]      N requests one after another, GAP seconds apart
  probe.py burst N          N requests at once
  probe.py stats            the harness's call counters

One line per request: index, HTTP status, source, called|skipped, elapsed.
"""

import json
import os
import signal
import subprocess
import sys
import threading
import time
import urllib.request

BASE = "http://127.0.0.1:8081"
HERE = os.path.dirname(os.path.abspath(__file__))
PIDFILE = os.path.join(HERE, "pid")
LOG = os.path.join(HERE, "log")


def get(path, timeout=30):
    with urllib.request.urlopen(BASE + path, timeout=timeout) as r:
        return r.status, r.read().decode()


def restart():
    try:
        os.kill(int(open(PIDFILE).read()), signal.SIGKILL)
    except (OSError, ValueError):
        pass
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:  # the old process must release :8081
        try:
            get("/health", 0.5)
            time.sleep(0.1)
        except Exception:
            break
    with open(LOG, "w") as log:
        p = subprocess.Popen([sys.executable, "checkout_cb.py"], cwd=HERE,
                             stdout=log, stderr=log, start_new_session=True)
    open(PIDFILE, "w").write(str(p.pid))
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if p.poll() is not None:
            break
        try:
            get("/health", 0.5)
            return 0
        except Exception:
            time.sleep(0.1)
    print("checkout with your breaker did not start:")
    print("".join(open(LOG).readlines()[-15:]))
    return 1


def one(i, out):
    started = time.monotonic()
    try:
        status, body = get("/checkout")
        d = json.loads(body)
        line = "#%-3d %s %-8s %-7s %5dms" % (
            i, status, d.get("source"), "called" if d.get("called_pricing") else "skipped",
            int((time.monotonic() - started) * 1000))
    except Exception as exc:
        line = "#%-3d ERR %s %s" % (i, type(exc).__name__, exc)
    out[i] = line


def main(argv):
    cmd = argv[1] if len(argv) > 1 else "seq"
    if cmd == "restart":
        return restart()
    if cmd == "stats":
        print(get("/stats")[1].strip())
        return 0
    n = int(argv[2]) if len(argv) > 2 else 10
    out = {}
    if cmd == "burst":
        ts = [threading.Thread(target=one, args=(i, out)) for i in range(1, n + 1)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
    else:
        gap = float(argv[3]) if len(argv) > 3 else 0
        for i in range(1, n + 1):
            one(i, out)
            print(out[i], flush=True)
            if gap:
                time.sleep(gap)
        return 0
    for i in sorted(out):
        print(out[i])
    return 0


sys.exit(main(sys.argv))
