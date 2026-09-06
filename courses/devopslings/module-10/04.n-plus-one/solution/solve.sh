#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The loop asked the database for one customer at a time. The join asks for all
# two hundred in the statement that already knows which customers they are.
set -euo pipefail

cat > /work/app/page.sh <<'SH'
#!/usr/bin/env bash
# Renders the "recent orders" page: the two hundred newest orders, each with
# the email address of the customer who placed it.
set -euo pipefail

export PGPASSWORD=devopslings

psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 -c "
  SELECT o.id, c.email, o.total_cents
    FROM orders o
    JOIN customers c ON c.id = o.customer_id
   ORDER BY o.id DESC
   LIMIT 200"
SH
chmod +x /work/app/page.sh

install -d /work/answers
cat > /work/answers/n-plus-one.md <<'MD'
# The page nobody can find in the slow-query log

# The statement the page runs too many times, written the way
# pg_stat_statements records it — with its literals replaced by $1.
statement: SELECT email FROM customers WHERE id = $1

# How many times ONE render of the page runs that statement.
calls-per-render: 200
MD

echo "page.sh rewritten as one join, answers written"
