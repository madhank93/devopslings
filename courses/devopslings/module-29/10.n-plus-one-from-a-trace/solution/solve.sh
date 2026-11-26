#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The trace of the ticket's order shows one 'SELECT shop.products' span per
# line item, each about a millisecond: the time is in the number of round
# trips, not in any one query. A join fetches every item in one.
set -euo pipefail
python3 - <<'PY'
p = "/obs/apps/checkout.py"
s = open(p).read()
s = s.replace('''    for product_id, qty in query("SELECT product_id, qty FROM order_items WHERE order_id = ?", (order_id,)):
        sku, name, price = query("SELECT sku, name, price_cents FROM products WHERE id = ?", (product_id,))[0]
        items.append({"sku": sku, "name": name, "qty": qty, "price_cents": price})''',
'''    for sku, name, qty, price in query(
            "SELECT p.sku, p.name, i.qty, p.price_cents FROM order_items i JOIN products p"
            " ON p.id = i.product_id WHERE i.order_id = ? ORDER BY i.id", (order_id,)):
        items.append({"sku": sku, "name": name, "qty": qty, "price_cents": price})''')
open(p, "w").write(s)
PY
grep -q 'JOIN products' /obs/apps/checkout.py
ticket=$(cat /obs/data/ticket)
n=$(python3 -c "import sqlite3; print(sqlite3.connect('/obs/data/shop.db').execute('SELECT count(*) FROM order_items WHERE order_id = $ticket').fetchone()[0])")
sed -i -e "s/^span: ?.*/span: SELECT shop.products/" -e "s/^count: ?.*/count: $n/" /obs/answers/n-plus-one.txt
