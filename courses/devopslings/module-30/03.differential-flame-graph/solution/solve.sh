#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# Pyroscope's diff of version=v1 against version=v2 is red in one place:
# format_price, and the new _symbol under it. v2 replaced the SYMBOLS dict
# built once at import with a linear scan of the currency list on every
# call. Reverting money.py alone brings v2 level with v1.
set -euo pipefail
mkdir -p /obs/answers
echo "regression=format_price" > /obs/answers/regression.txt
cp /obs/catalog/v1/money.py /obs/catalog/v2/money.py
