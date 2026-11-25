#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# ledger's server span starts before checkout's client span that called it,
# by the same few seconds in every trace, while fulfil's nests: ledger's host
# clock is behind. Stepping that clock back to true (what `chronyc makestep`
# does on a real host) fixes every timestamp the host writes, spans included.
set -euo pipefail
ms=$(python3 -c 'print(round(abs(float(open("/obs/data/clock-skew.truth").read())) * 1000))')
sed -i -e 's/^cause: ?.*/cause: ledger host clock is behind (clock skew)/' -e 's/^host: ?.*/host: ledger/' \
  -e "s/^offset_ms: ?.*/offset_ms: -$ms/" /obs/answers/clock-skew.txt
echo 0 > /obs/hosts/ledger/clock-offset
