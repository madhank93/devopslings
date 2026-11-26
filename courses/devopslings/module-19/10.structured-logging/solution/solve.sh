#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A JSON formatter writes level, msg and every field passed in `extra`; each
# call names its event in msg and passes the order, warehouse and the rest as
# fields, so no value is ever spliced into the text.
set -euo pipefail
python3 - <<'PY'
p = "/obs/apps/lab.py"
s = open(p).read()
swaps = [
    ('handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))',
     'class JsonFormatter(logging.Formatter):\n'
     '    def format(self, record):\n'
     '        rec = {"ts": self.formatTime(record), "level": record.levelname.lower(), "msg": record.getMessage()}\n'
     '        rec.update(getattr(record, "fields", {}))\n'
     '        return json.dumps(rec)\n'
     '\n'
     '\n'
     'handler.setFormatter(JsonFormatter())'),
    ('log.info("order %s picked in %s, %d items", order, warehouse, items)',
     'log.info("order picked", extra={"fields": {"order_id": order, "warehouse": warehouse, "items": items}})'),
    ('log.error("order %s rejected by courier %s in %s: %s", order, courier, warehouse,\n'
     '                  random.choice(REASONS))',
     'log.error("courier rejected order", extra={"fields": {\n'
     '            "order_id": order, "warehouse": warehouse, "courier": courier, "reason": random.choice(REASONS)}})'),
    ('log.info("order %s handed to %s in %s", order, courier, warehouse)',
     'log.info("order handed to courier", extra={"fields": {"order_id": order, "warehouse": warehouse, "courier": courier}})'),
    ('log.info("restocked shelf %s with %d units of sku %d",\n'
     '                 random.choice(["A-12", "B-812", "C-4"]), random.randint(10, 90),\n'
     '                 random.choice([1812, 812, 3344]))',
     'log.info("shelf restocked", extra={"fields": {\n'
     '            "shelf": random.choice(["A-12", "B-812", "C-4"]), "units": random.randint(10, 90),\n'
     '            "sku": random.choice([1812, 812, 3344])}})'),
]
for old, new in swaps:
    assert old in s, old
    s = s.replace(old, new)
open(p, "w").write(s)
PY
echo "key: warehouse" > /obs/answers/structured-logging.txt
