#!/usr/bin/env bash
# Reference solution — used by the contract test, not by students.
#
# A least-squares fit of N·X(1)/X(N) - 1 = sigma(N-1) + kappa·N(N-1) to the six
# budgeted runs gives sigma ≈ 0.027 and kappa ≈ 0.0041, so the peak is at
# sqrt((1 - sigma) / kappa) ≈ 15 nodes, about 290 commits a second.
# Runs on the host with cwd = sandboxes/chaos-stack.
set -euo pipefail
mkdir -p answers
cat > answers/usl.txt <<'TXT'
sigma=0.027
kappa=0.0041
peak_nodes=15
peak_per_s=290
cannot_tell=It does not say why: which lock or resource causes the contention and the coherency cost, or how the curve moves if the workload changes.
TXT
