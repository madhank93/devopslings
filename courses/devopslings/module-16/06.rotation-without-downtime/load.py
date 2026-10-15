"""Steady traffic at orders until /work/stop appears (or 150s pass).

Prints `ok N`, `fail N`, then one `failure <seconds-in> <reason>` line per
failed request, first ones first.
"""
import os
import threading
import time
import urllib.error
import urllib.request

WORKERS, PAUSE, CAP = 4, 0.05, 150
start = time.time()
results, lock = [], threading.Lock()


def worker():
    while not os.path.exists("/work/stop") and time.time() - start < CAP:
        t = time.time() - start
        try:
            with urllib.request.urlopen("http://orders:8080/order", timeout=3) as r:
                r.read()
            res = (t, None)
        except urllib.error.HTTPError as e:
            res = (t, e.read().decode(errors="replace").strip() or f"HTTP {e.code}")
        except Exception as e:
            res = (t, f"no answer from orders: {e}")
        with lock:
            results.append(res)
        time.sleep(PAUSE)


threads = [threading.Thread(target=worker) for _ in range(WORKERS)]
for th in threads:
    th.start()
for th in threads:
    th.join()

fails = sorted(r for r in results if r[1])
print(f"ok {len(results) - len(fails)}")
print(f"fail {len(fails)}")
for t, why in fails:
    print(f"failure {t:.1f} {why}")
