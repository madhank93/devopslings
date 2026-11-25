#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Set the HTTP semantic-convention attributes in the SDK: the method, the
# integer status code, and the route as the template the path matched.
set -euo pipefail
python3 - <<'PY'
p = "/obs/apps/checkout.py"
s = open(p).read()
for a, b in [
    ('''    ("GET", r"/orders/(\\d+)", get_order),
    ("GET", r"/customers/(\\d+)/orders", customer_orders),
    ("POST", r"/orders", place_order),
''', '''    ("GET", r"/orders/(\\d+)", get_order, "/orders/{id}"),
    ("GET", r"/customers/(\\d+)/orders", customer_orders, "/customers/{id}/orders"),
    ("POST", r"/orders", place_order, "/orders"),
'''),
    ('''            span.set_attribute("method", self.command)
            span.set_attribute("url", self.path)''', '''            span.set_attribute("http.request.method", self.command)
            span.set_attribute("url.path", self.path)'''),
    ("for method, pattern, fn in ROUTES:", "for method, pattern, fn, route in ROUTES:"),
    ('''                if m and method == self.command:
''', '''                if m and method == self.command:
                    span.set_attribute("http.route", route)
                    span.update_name(f"{method} {route}")
'''),
    ('span.set_attribute("httpStatus", str(status))', 'span.set_attribute("http.response.status_code", status)'),
]:
    assert s.count(a) == 1, a
    s = s.replace(a, b)
open(p, "w").write(s)
PY
