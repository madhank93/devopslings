"""check.py ORIGINAL_PY ANSWER_PY — what the lesson's check needs to know about
an edited quote.py, as one JSON line:

  same_prices      every order in orders.py is priced as the original prices it
  dumps_at_info    json.dumps calls while quoting them with DEBUG off
  debug_has_order  with DEBUG on, quote() logs a record carrying the order's id
                   and its lines
"""
import importlib.util
import json
import logging
import sys

from orders import ORDERS


def load(path, name):
    s = importlib.util.spec_from_file_location(name, path)
    m = importlib.util.module_from_spec(s)
    s.loader.exec_module(m)
    return m


original = load(sys.argv[1], "original")
answer = load(sys.argv[2], "quote")

calls = 0
real_dumps = json.dumps


def counting_dumps(*a, **k):
    global calls
    calls += 1
    return real_dumps(*a, **k)


class Keep(logging.Handler):
    def __init__(self):
        super().__init__(logging.DEBUG)
        self.messages = []

    def emit(self, record):
        self.messages.append(record.getMessage())


root = logging.getLogger()
keep = Keep()
root.handlers[:] = [keep]

root.setLevel(logging.INFO)
json.dumps = counting_dumps
try:
    prices = [answer.quote(o) for o in ORDERS]
finally:
    json.dumps = real_dumps
same = prices == [original.quote(o) for o in ORDERS]

root.setLevel(logging.DEBUG)
o = ORDERS[7]
answer.quote(o)
has_order = any(o["id"] in m and o["lines"][0]["sku"] in m for m in keep.messages)
print(json.dumps({"same_prices": same, "dumps_at_info": calls, "debug_has_order": has_order}))
