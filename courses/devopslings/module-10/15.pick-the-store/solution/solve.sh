#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
set -euo pipefail

cat > answers/verdict.md <<'ANS'
# One line per case.

case-1: store=redis because=durability
case-2: store=postgres because=consistency
case-3: store=postgres because=cardinality
case-4: store=timeseries because=accesspattern
ANS

echo "four verdicts written to answers/verdict.md"
