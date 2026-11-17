#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A third of quote()'s CPU went to json.dumps building a DEBUG message that
# the INFO-level logger then threw away: an f-string is built before debug()
# is called. Guarding it with isEnabledFor keeps the line for when DEBUG is on.
# Runs on the host with cwd = sandboxes/chaos-stack.
set -euo pipefail
set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-20/*.flame-graph
mkdir -p answers
cp "$1/solution/quote.py" answers/quote.py
echo "hot_function=json.dumps" > answers/flame-graph.txt
