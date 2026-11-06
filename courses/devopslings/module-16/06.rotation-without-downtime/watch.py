"""Times a rotation from outside, on one clock, until /work/stop appears (or
150s pass).

usage: watch.py <old-user> <old-password> <bao-token>

Prints `published <s>` when secret/orders/db first holds anything but the old
credential alone, and `cut <s>` when the old credential first stops logging in
(two refusals in a row), as seconds since start.
"""
import json
import os
import sys
import time
import urllib.request

import psycopg

user, password, token = sys.argv[1:4]
start = time.time()
published = cut = refused_at = None

while not os.path.exists("/work/stop") and time.time() - start < 150 and cut is None:
    now = time.time() - start
    if published is None:
        req = urllib.request.Request("http://bao:8200/v1/secret/data/orders/db",
                                     headers={"X-Vault-Token": token})
        try:
            with urllib.request.urlopen(req, timeout=2) as r:
                d = json.load(r)["data"]["data"]
            if d != {"username": user, "password": password}:
                published = now
                print(f"published {now:.2f}", flush=True)
        except Exception:
            pass
    try:
        psycopg.connect(host="db", dbname="app", user=user, password=password,
                        connect_timeout=2).close()
        refused_at = None
    except psycopg.OperationalError:
        if refused_at is not None:
            cut = refused_at
            print(f"cut {cut:.2f}", flush=True)
        else:
            refused_at = now
    time.sleep(0.05)
