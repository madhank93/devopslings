#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The numbers are read out of the plan rather than written in, because they are
# properties of this database right now: the estimate depends on the statistics
# ANALYZE last collected, and the actual count depends on the seed. A student
# does this by reading the plan; the script does the same thing with sed.
set -euo pipefail

export PGPASSWORD=devopslings
psql() { command psql -qtAX -v ON_ERROR_STOP=1 -U postgres -d shop -h 127.0.0.1 "$@"; }

query=$(grep -v '^ *SET ' /work/report.sql | tr -d ';' | tr '\n' ' ')
plan=$(psql -c 'SET max_parallel_workers_per_gather = 0' \
            -c "EXPLAIN (ANALYZE, FORMAT JSON) ${query}")

scan_node=$(printf '%s' "$plan" | sed -n 's/.*"Node Type": "\([^"]*\)".*/\1/p' | grep -iE 'scan' | tail -1)
est=$(printf '%s' "$plan" | sed -n 's/.*"Plan Rows": \([0-9]*\).*/\1/p' | tail -1)
act=$(printf '%s' "$plan" | sed -n 's/.*"Actual Rows": \([0-9]*\).*/\1/p' | tail -1)

case "$scan_node" in
  *"Seq Scan"*)         scan=seq ;;
  *"Bitmap Heap Scan"*) scan=bitmap ;;
  *"Index Only Scan"*)  scan=index-only ;;
  *"Index Scan"*)       scan=index ;;
  *)                    scan=seq ;;
esac

install -d /work/answers
cat > /work/answers/plan.md <<MD
# Reading the plan

# The scan type the plan chose for \`orders\`. One of:
#   seq | index | index-only | bitmap
scan: ${scan}

# Rows the planner ESTIMATED it would get from that scan node.
estimated-rows: ${est}

# Rows it ACTUALLY got from that node.
actual-rows: ${act}

# Where the estimate first went wrong, and why. Name the expression the
# planner could not use statistics for.
why: The filter is not on reference, it is on reference::bigint — a cast, and therefore an expression the planner holds no statistics about. ANALYZE collects a histogram and most-common-values for the column as it is stored, which is text; nothing describes the distribution of that column interpreted as a number. So the estimate for the scan node is a default selectivity guess rather than anything derived from the data, and every decision above that node is made on that guess.
MD

echo "answers written: scan=${scan} estimated=${est} actual=${act}"
