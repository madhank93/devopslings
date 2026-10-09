"""Grades the queue after one consumer run.

    python3 grade.py <consumer exit status>

Runs next to orders.py in the consumer's container. Message n carries order n,
because orders.py seeds them in order.
"""

import sqlite3
import sys

from orders import DB, POISON_ORDER, order_body

TOTAL = 30
rc = int(sys.argv[1])
good = set(range(1, TOTAL + 1)) - {POISON_ORDER}

c = sqlite3.connect(DB)
msgs = {i: (s, a) for i, s, a in c.execute("SELECT id, status, attempts FROM messages")}
shipped = {r[0] for r in c.execute("SELECT DISTINCT order_id FROM shipped")}
dead = c.execute("SELECT message_id, body, error, attempts FROM dead_letter").fetchall()
dead_ids = {d[0] for d in dead}
pending = sorted(i for i, (s, _) in msgs.items() if s == "pending")
n_good = len(shipped & good)


def ids(xs):
    return ", ".join(str(x) for x in sorted(xs))


print(f"shipped {n_good} of {len(good)} good orders; pending {len(pending)}; dead_letter {len(dead)}")
print()

if POISON_ORDER in pending:
    tries = msgs[POISON_ORDER][1]
    if n_good < len(good):
        print("not yet: the queue is stuck behind message 4.")
        print(f"  After {'30s' if rc == 124 else 'the run'}, {n_good} of {len(good)} good orders had shipped and message 4 was")
        print(f"  still pending ({tries} attempts recorded). Its body can never be handled —")
        print(f"  {order_body(POISON_ORDER, True)}")
        print("  — so retrying it is all the consumer does, and every order behind it waits.")
    else:
        print(f"not yet: every good order shipped, but message 4 is still pending after")
        print(f"{tries} recorded attempts. It will never succeed, and nothing takes it out of the")
        print("queue: the consumer retries it for as long as it runs.")
    sys.exit(1)

if pending:
    print(f"not yet: messages {ids(pending)} are still pending — the consumer stopped")
    print(f"(exit status {rc}) before the queue was drained.")
    sys.exit(1)

if POISON_ORDER not in dead_ids:
    state = msgs.get(POISON_ORDER)
    where = "deleted from messages" if state is None else f"left in messages with status '{state[0]}'"
    print(f"not yet: message 4 was {where}, and it is not in dead_letter.")
    print("It never shipped, so that order is gone with no record anyone will look at —")
    print("a customer's order silently discarded. Park it in dead_letter instead.")
    sys.exit(1)

parked_good = dead_ids & good
if parked_good:
    tries = ", ".join(f"{d[0]} after {d[3]}" for d in dead if d[0] in parked_good)
    print(f"not yet: good orders were parked in dead_letter ({tries} attempts).")
    print("Each of them succeeds when retried — the stock service is only briefly busy.")
    print("dead_letter is for messages that will never succeed, so a message needs more")
    print("than one failure before it goes there.")
    sys.exit(1)

lost = good - shipped
if lost:
    print(f"not yet: orders {ids(lost)} never shipped, and they are not pending and not")
    print("in dead_letter: they left the queue without being handled.")
    sys.exit(1)

body = next(d[1] for d in dead if d[0] == POISON_ORDER)
if body != order_body(POISON_ORDER, True):
    print("not yet: message 4 is in dead_letter, but not with its original body. A parked")
    print("message is only useful if someone can see exactly what arrived and replay it.")
    sys.exit(1)

err = next(d[2] for d in dead if d[0] == POISON_ORDER)
print(f"PASS — message 4 parked ({err or 'no error recorded'}), all {len(good)} good orders shipped.")
