#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# The consumer counts attempts per message, backs off between them, and after
# five failures moves the message to dead_letter with its body and last error.
# Five is enough to ride out the stock service's one-off busy errors, and
# bounded, so a message that can never succeed stops blocking the queue.
#
# Runs on the host; the check deploys whatever is in the scratch directory.
set -euo pipefail

set -- "$DEVOPSLINGS_ROOT"/courses/devopslings/module-21/*.dead-letter-queue
cp "$1/solution/consumer.py" "$DEVOPSLINGS_ROOT/scratch/dead-letter-queue/consumer.py"
